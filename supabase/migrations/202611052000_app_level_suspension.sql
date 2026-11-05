-- 停權改成 App 層級旗標（#331；使用者決定 2026-11-05「停權是停 APP 的權限而已」）：
--   * 停權中的帳號照常可以登入、瀏覽、管理帳號、申請與取消刪除帳號，也照常
--     會被到期刪除；被擋下的只有 App 的寫入（使用者確認 PM_ANS #331）：新增
--     停車點、修改建議（含「已經不能停」）、車友回報目擊、檢舉（flag 與內容
--     不當）、改名稱（display_name）、改頭像與移除頭像（profile_avatar_url
--     與頭像 Storage，Q_331_AVATAR、v183 P12）、確認點位／投票。
--     hidden_riders 同步、帳號管理、刪除與取消刪除帳號放行。
--   * 停權存在 private.user_suspensions，不再用 Supabase Auth 的 banned_until
--     （它會連登入都擋掉，停權的人就沒辦法自助刪除帳號）。
--   * 錯誤碼 account.suspended：Edge Function 回 403
--     {"error":"account.suspended","until":<ISO|null>}；資料庫（api_v1、
--     寫入的防線觸發器）raise sqlstate 'PT403' message 'account.suspended'，
--     detail 是 {"until":<ISO|null>}。until 為 null 代表無限期。
--   * 帳號刪除時停權列跟著刪除（on delete cascade）；停權的紀錄是
--     admin_audit_log 的 ban_user／unban_user（照 #267 保留 2 年後去識別化），
--     和原本 Auth ban 一樣。防濫用雜湊的保留規則（202611012100）不受影響。

-- ===== 1. 停權表 =====
create table private.user_suspensions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- null：無限期，直到管理員解除。
  until timestamptz,
  reason text not null check (char_length(reason) between 1 and 500),
  -- 管理員，或規則評分的系統操作者 00000000-…；沒有外鍵，管理員刪帳號後照留。
  created_by uuid not null,
  created_at timestamptz not null default now()
);
alter table private.user_suspensions enable row level security;
revoke all on private.user_suspensions from public,anon,authenticated,service_role;
comment on table private.user_suspensions is
  'App 層級停權（#331）：只擋 App 的寫入，不擋登入與帳號管理。until 為 null 代表無限期；過期的列視為未停權。';

-- 規則評分（洗版）停權的操作者，與原本 submit-sighting 的 systemActor 相同。
create function private.suspension_system_actor() returns uuid
language sql immutable set search_path='' as $$ select '00000000-0000-0000-0000-000000000000'::uuid $$;
-- 管理站與稽核顯示「無限期」用的時間：管理站把 10 年以上視為無限期
-- （lib/admin/users/user_models.dart），回傳形狀維持 banned_until 時間。
create function private.suspension_display_until(p_until timestamptz) returns timestamptz
language sql immutable set search_path='' as $$
  select coalesce(p_until,'9999-12-31T00:00:00Z'::timestamptz)
$$;
revoke execute on function private.suspension_system_actor(),private.suspension_display_until(timestamptz)
  from public,anon,authenticated,service_role;

-- ===== 2. 查詢 =====
create function public.is_suspended(uid uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from private.user_suspensions s
    where s.user_id=uid and (s.until is null or s.until>now()))
$$;
-- {suspended, until}：until 是 ISO 時間或 null（無限期，或沒有停權）。
create function public.suspension_status(uid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select coalesce(
    (select jsonb_build_object('suspended',true,'until',s.until) from private.user_suspensions s
      where s.user_id=uid and (s.until is null or s.until>now())),
    jsonb_build_object('suspended',false,'until',null))
$$;
revoke execute on function public.is_suspended(uuid),public.suspension_status(uuid) from public,anon,authenticated;
grant execute on function public.is_suspended(uuid),public.suspension_status(uuid) to service_role;

-- 停權時 raise PT403 account.suspended（detail {"until":…}）。寫入的
-- api_v1 函式開頭先呼叫它（supabase/tests/app_suspension_test.sql 檢查）。
create function private.require_not_suspended(p_user uuid) returns void
language plpgsql stable security definer set search_path='' as $$
declare v jsonb:=public.suspension_status(p_user);
begin
  if (v->>'suspended')::boolean then
    raise sqlstate 'PT403' using message='account.suspended',
      detail=jsonb_build_object('until',v->'until')::text;
  end if;
end $$;
revoke execute on function private.require_not_suspended(uuid) from public,anon,authenticated,service_role;

-- ===== 3. 停權與解除（admin-users 與規則評分共用）=====
-- 一次完成停權、稽核；回傳 {before, after}（顯示用的 banned_until，未停權為
-- null）。p_duration：7d、30d、indefinite、none（解除）。p_extend_only：
-- 只延長不縮短（規則評分用，不能把管理員給的較長停權改短）。
create function private.suspension_set(p_actor uuid,p_user uuid,p_duration text,p_note text,
  p_extend_only boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_note text:=btrim(coalesce(p_note,''));
  v_old private.user_suspensions;
  v_active boolean;
  v_before timestamptz; v_after timestamptz;
  v_until timestamptz;
begin
  if p_actor is null or p_user is null or p_duration is null
     or p_duration not in ('7d','30d','indefinite','none') or char_length(v_note) not between 1 and 500 then
    raise exception 'invalid user suspension' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('suspension:'||p_user::text,0));
  if not exists(select 1 from auth.users u where u.id=p_user) then
    raise exception 'user not found' using errcode='P0002';
  end if;
  select * into v_old from private.user_suspensions s where s.user_id=p_user;
  v_active:=found and (v_old.until is null or v_old.until>now());
  v_before:=case when v_active then private.suspension_display_until(v_old.until) end;
  if p_duration='none' then
    delete from private.user_suspensions s where s.user_id=p_user;
    -- 解除時一併解除目擊的洗版停權（原本 rider_sightings_unban 觸發器）。
    update public.rider_sighting_scores s set suspended_until=null,updated_at=now()
      where s.user_id=p_user and s.suspended_until is not null;
  else
    if exists(select 1 from auth.users u where u.id=p_user and u.raw_app_meta_data->>'role'='admin') then
      raise exception 'administrators cannot be suspended' using errcode='42501';
    end if;
    v_until:=case p_duration when '7d' then now()+interval '7 days' when '30d' then now()+interval '30 days' end;
    if p_extend_only and v_active and (v_old.until is null or v_old.until>=v_until) then
      return jsonb_build_object('before',v_before,'after',v_before);
    end if;
    insert into private.user_suspensions as s(user_id,until,reason,created_by)
      values(p_user,v_until,v_note,p_actor)
      on conflict(user_id) do update set until=excluded.until,reason=excluded.reason,
        created_by=excluded.created_by,created_at=now();
    v_after:=private.suspension_display_until(v_until);
  end if;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(p_actor,case when p_duration='none' then 'unban_user' else 'ban_user' end,'auth.users',p_user::text,
    jsonb_build_object('banned_until',v_before),
    jsonb_build_object('banned_until',v_after,'duration',p_duration),v_note);
  return jsonb_build_object('before',v_before,'after',v_after);
end $$;
revoke execute on function private.suspension_set(uuid,uuid,text,text,boolean) from public,anon,authenticated,service_role;

-- admin-users（service role）呼叫；actor 是它驗證過的管理員（role 與 aal2）。
-- p_action：ban（p_duration 7d／30d／indefinite）或 unban。
create function public.admin_set_user_suspension(p_actor uuid,p_user uuid,p_action text,p_duration text,p_note text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
begin
  if p_action is null or p_action not in ('ban','unban') or (p_action='ban' and coalesce(p_duration,'')='none') then
    raise exception 'invalid user suspension' using errcode='22023';
  end if;
  return private.suspension_set(p_actor,p_user,case when p_action='unban' then 'none' else p_duration end,p_note);
end $$;
revoke execute on function public.admin_set_user_suspension(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_set_user_suspension(uuid,uuid,text,text,text) to service_role;

-- 不再有 Auth ban 可以記錄：admin-users 與 submit-sighting 都改用上面的函式。
drop function public.admin_record_user_ban(uuid,uuid,text,timestamptz,timestamptz,text,text);

-- ===== 4. 目擊的洗版停權 =====
-- 停權帳號與洗版停權的騎士一樣不能回報目擊，回報也不顯示、不算入封閉建議。
create or replace function public.rider_suspended(p_user uuid) returns boolean
language sql stable set search_path='' as $$
  select exists(select 1 from public.rider_sighting_scores s where s.user_id=p_user and s.suspended_until>now())
    or public.is_suspended(p_user);
$$;
revoke all on function public.rider_suspended(uuid) from public,anon,authenticated;

-- apply_sighting() 設洗版停權（7 天）時，同一個交易內停權整個帳號，並寫稽核
-- （原本由 submit-sighting 另外呼叫 Auth Admin API）。
create function public.rider_flood_suspension() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform private.suspension_set(private.suspension_system_actor(),new.user_id,'7d',
    '騎士回報洗版，自動停權 7 天（規則評分，決定 50）',true);
  return null;
end $$;
revoke execute on function public.rider_flood_suspension() from public,anon,authenticated;
create trigger rider_flood_suspension after insert or update of suspended_until on public.rider_sighting_scores
  for each row when (new.suspended_until>now()) execute function public.rider_flood_suspension();

-- 解除改由 private.suspension_set() 處理；Auth banned_until 不再使用。
drop trigger rider_sightings_unban on auth.users;
drop function public.rider_sightings_unban();

-- ===== 5. 寫入的防線 =====
-- apply_report() 每個動作（新增、確認、檢舉、修改、刪除）都先寫一筆
-- rate_limit_events；apply_sighting() 寫 rider_sightings。Edge Function
-- 會先檢查並回 403，這兩個觸發器擋下漏網的呼叫。
create function public.suspension_write_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.user_id is not null then
    perform private.require_not_suspended(new.user_id);
  end if;
  return new;
end $$;
revoke execute on function public.suspension_write_guard() from public,anon,authenticated;
create trigger rate_limit_events_suspension before insert on public.rate_limit_events
  for each row execute function public.suspension_write_guard();
create trigger rider_sightings_suspension before insert on public.rider_sightings
  for each row execute function public.suspension_write_guard();

-- ===== 6. 名稱與頭像 =====
-- App 用 supabase.auth.updateUser 寫 user_metadata 的 display_name、
-- profile_avatar_url。停權中這兩個鍵的變更不生效：保留舊值（原本沒有就
-- 拿掉），不丟錯誤；其他鍵（登入時 Google／Apple 合併的資料）照常更新。
-- BEFORE 觸發器先於 contributor_attribution 的 AFTER 觸發器（與 #327 的
-- contributor_handle_on_name），它們看到的就是保留後的名稱。
create function public.suspended_profile_freeze() returns trigger
language plpgsql security definer set search_path='' as $$
declare k text;
begin
  if not public.is_suspended(new.id) then return new; end if;
  foreach k in array array['display_name','profile_avatar_url'] loop
    if coalesce(old.raw_user_meta_data,'{}'::jsonb)->k is distinct from coalesce(new.raw_user_meta_data,'{}'::jsonb)->k then
      new.raw_user_meta_data:=case when coalesce(old.raw_user_meta_data,'{}'::jsonb) ? k
        then jsonb_set(coalesce(new.raw_user_meta_data,'{}'::jsonb),array[k],old.raw_user_meta_data->k)
        else coalesce(new.raw_user_meta_data,'{}'::jsonb)-k end;
    end if;
  end loop;
  return new;
end $$;
revoke execute on function public.suspended_profile_freeze() from public,anon,authenticated;
create trigger suspended_profile_freeze before update of raw_user_meta_data on auth.users
  for each row execute function public.suspended_profile_freeze();

-- 頭像檔案（motopark-avatars）：停權中不能上傳新頭像，也不能刪掉現有的
-- （刪掉等於移除頭像）。Storage 的 policy 以呼叫者身分執行，所以用一支只看
-- 自己（auth.uid()）的函式；帳號刪除用 service role 刪頭像，不受影響。
create function public.caller_suspended() returns boolean
language sql stable security definer set search_path='' as $$
  select public.is_suspended(auth.uid())
$$;
revoke execute on function public.caller_suspended() from public,anon;
grant execute on function public.caller_suspended() to authenticated;
-- 其餘與 202610250060_profile_avatars.sql 相同。
drop policy profile_avatars_insert_own on storage.objects;
create policy profile_avatars_insert_own on storage.objects for insert to authenticated
  with check(bucket_id='motopark-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text)
    and array_length(storage.foldername(name),1)=1
    and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'
    and coalesce((select auth.jwt())->>'is_anonymous','false')<>'true'
    and not (select public.caller_suspended()));
drop policy profile_avatars_delete_own on storage.objects;
create policy profile_avatars_delete_own on storage.objects for delete to authenticated
  using(bucket_id='motopark-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text)
    and coalesce((select auth.jwt())->>'is_anonymous','false')<>'true'
    and not (select public.caller_suspended()));

-- ===== 7. App 讀自己的停權狀態 =====
create function api_v1.my_account_status() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  v_user uuid:=auth.uid();
  v jsonb;
begin
  if v_user is null then
    raise sqlstate 'PT401' using message='auth.sign_in_required';
  end if;
  v:=public.suspension_status(v_user);
  return jsonb_build_object('suspended',v->'suspended','suspended_until',v->'until');
end $$;
revoke execute on function api_v1.my_account_status() from public,anon;
grant execute on function api_v1.my_account_status() to authenticated;

-- ===== 8. 管理站的使用者清單 =====
-- banned_until 改從 private.user_suspensions 讀；無限期顯示為 9999-12-31。
-- 其餘與 202610260260_admin_users.sql 相同。
create or replace function public.admin_users(p_query text default '',p_limit integer default 50)
returns table(
  id uuid,display_name text,email_masked text,providers text[],is_admin boolean,
  created_at timestamptz,last_sign_in_at timestamptz,banned_until timestamptz,deleted boolean,
  reports_30d integer,last_report_at timestamptz
) language plpgsql stable security definer set search_path='' as $$
declare
  v_query text:=btrim(coalesce(p_query,''));
  v_limit integer:=coalesce(p_limit,50);
  v_since timestamptz:=now()-interval '30 days';
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  -- Cast here: a cast inside the query's CASE could still be evaluated.
  if v_query ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id:=v_query::uuid;
  end if;
  if char_length(v_query)>100 or v_limit not between 1 and 100 then
    raise exception 'invalid user search' using errcode='22023';
  end if;
  return query
  with matched as (
    select u.* from auth.users u
    where case
      when v_query='' then exists(select 1 from public.rate_limit_events r where r.user_id=u.id and r.created_at>=v_since)
      when v_id is not null then u.id=v_id
      when position('@' in v_query)>0 then lower(u.email)=lower(v_query)
      -- Wildcards the admin types are plain text.
      else public.contributor_display_name(u.raw_user_meta_data)
        ilike '%'||replace(replace(replace(v_query,'\','\\'),'%','\%'),'_','\_')||'%'
    end
  ), stats as (
    select m.id,count(r.id)::integer as reports,max(r.created_at) as last_at
    from matched m left join public.rate_limit_events r on r.user_id=m.id and r.created_at>=v_since
    group by m.id
  )
  select m.id,public.contributor_display_name(m.raw_user_meta_data),public.admin_mask_email(m.email),
    coalesce((select array_agg(distinct i.provider order by i.provider) from auth.identities i where i.user_id=m.id),
      case when m.is_anonymous then array['anonymous'] else array[]::text[] end),
    coalesce(m.raw_app_meta_data->>'role','')='admin',
    m.created_at,m.last_sign_in_at,
    (select private.suspension_display_until(s.until) from private.user_suspensions s
      where s.user_id=m.id and (s.until is null or s.until>now())),
    m.deleted_at is not null,
    s.reports,
    (select max(r.created_at) from public.rate_limit_events r where r.user_id=m.id)
  from matched m join stats s on s.id=m.id
  order by s.last_at desc nulls last,m.created_at desc
  limit v_limit;
end;
$$;
revoke execute on function public.admin_users(text,integer) from public,anon;
grant execute on function public.admin_users(text,integer) to authenticated;

-- ===== 9. 轉換現有的 Auth ban =====
-- 仍有效的 Auth ban 與目擊洗版停權轉成 user_suspensions，再解除 Auth ban。
-- Auth ban 的「無限期」是 876000h（約 100 年），10 年以上視為無限期。原因
-- 取該帳號最新一筆 ban_user 稽核的 note。可重跑：已有停權列的帳號不重複
-- 寫入，Auth ban 解除後就不會再被選到。
insert into private.user_suspensions(user_id,until,reason,created_by,created_at)
select x.user_id,
  case when x.until>now()+interval '10 years' then null else x.until end,
  coalesce(a.note,'由 Auth 停權轉換（#331）'),
  coalesce(a.actor,private.suspension_system_actor()),
  coalesce(a.created_at,now())
from (
  select t.user_id,max(t.until) as until from (
    select u.id as user_id,u.banned_until as until from auth.users u where u.banned_until>now()
    union all
    select s.user_id,s.suspended_until from public.rider_sighting_scores s where s.suspended_until>now()
  ) t group by t.user_id
) x
left join lateral (
  select l.note,l.actor,l.created_at from public.admin_audit_log l
  where l.target_table='auth.users' and l.target_id=x.user_id::text and l.action='ban_user'
    and char_length(btrim(l.note)) between 1 and 500
  order by l.created_at desc limit 1
) a on true
on conflict (user_id) do nothing;

update auth.users u set banned_until=null where u.banned_until is not null;
