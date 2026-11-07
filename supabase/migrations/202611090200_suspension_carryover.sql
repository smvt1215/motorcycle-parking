-- 停權延續到同一登入身分的新帳號（使用者決定 PM_ANS Q_331_REREGISTER，選 B）：
-- #331 的停權以 user_id 為鍵、帳號刪除時 cascade，所以停權者刪帳號後用同一個
-- Google／Apple 帳號再登入，就是沒有停權的新帳號。這裡只針對刪除當下停權仍
-- 有效的帳號，保留「身分 HMAC＋到期日」到停權結束；無限期停權最多保留 180 天。
--   * 不存 user_id、email、sub 原文與停權原因。金鑰獨立於 contributor_handle，
--     HMAC 輸入也帶用途字串。
--   * 寫入：auth.users 的 BEFORE DELETE 觸發器。外鍵 cascade 是刪除之後才執行
--     的內部觸發器，這時 identities 與 user_suspensions 都還在。自助刪除與客服
--     刪除都走 account-deletion 的 auth.admin.deleteUser(user, false)（硬刪除），
--     直接 delete from auth.users 也涵蓋。寫入出錯時只記錄 warning、刪除照常
--     繼續：使用者刪除帳號的權利優先於防重新註冊，而且這裡只影響停權中的帳號
--     （coordinator 決定，#355）。
--     軟刪除（should_soft_delete）不會觸發，專案沒有使用。
--   * 恢復：auth.identities 的 AFTER INSERT 觸發器。新帳號與連結既有帳號（同
--     email 自動連結）都經過這裡：Auth 先建 auth.users，再於同一交易建
--     identities。這個觸發器絕對不能讓登入失敗：出錯時只記錄 warning、不往外
--     丟，那一列留到到期，恢復的結果也一併復原。
--   * Google＋Apple 兩個身分各一列。恢復只刪用掉的那一列，另一列照留：這個人
--     也可能用另一個身分開另一個帳號，那個帳號一樣要恢復。之後把另一個身分
--     連到同一帳號時，只延長不縮短（p_extend_only），並刪除那一列。
--   * 同一身分再次刪除時會再寫入，新的狀態蓋掉舊列，180 天上限重新起算。這是
--     預期行為：恢復後又刪除，代表這個身分的停權到這時仍然有效。
--   * 到期清除併入 account_data_retention（每日 pg_cron），不另開排程；過期沒清
--     到的列在恢復時也不算數。

-- ===== 0. 期限 =====
-- 無限期停權的保留上限；有到期日的停權保留到到期日。
create function private.retention_suspension_carryover() returns interval
language sql immutable security definer set search_path='' as $$ select interval '180 days' $$;
revoke execute on function private.retention_suspension_carryover() from public,anon,authenticated,service_role;

-- ===== 1. 金鑰與資料表 =====
create table private.suspension_carryover_key (
  id boolean primary key default true check (id),
  key bytea not null check (octet_length(key)>=32)
);
insert into private.suspension_carryover_key(key) values(extensions.gen_random_bytes(32));
alter table private.suspension_carryover_key enable row level security;
revoke all on private.suspension_carryover_key from public,anon,authenticated,service_role;

create table private.suspension_carryover (
  identity_hash bytea primary key check (octet_length(identity_hash)=32),
  -- null：無限期。
  until timestamptz,
  -- 過了這個時間就不恢復，由 account_data_retention 刪除。
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (until is null or until=expires_at)
);
create index suspension_carryover_expires_idx on private.suspension_carryover(expires_at);
alter table private.suspension_carryover enable row level security;
revoke all on private.suspension_carryover from public,anon,authenticated,service_role;
comment on table private.suspension_carryover is
  '刪除當下停權仍有效的帳號的身分 HMAC 與到期日（#331）：同一身分重新建立帳號時恢復停權；保留到停權結束，無限期最多 180 天。';

-- text 不會含 NUL，用它分隔就不會有 provider 與 sub 拼接的歧義。
create function private.suspension_carryover_hash(p_provider text,p_sub text) returns bytea
language sql stable security definer set search_path='' as $$
  select extensions.hmac(
    convert_to('suspension-carryover','UTF8')||'\x00'::bytea
      ||convert_to(p_provider,'UTF8')||'\x00'::bytea||convert_to(p_sub,'UTF8'),
    k.key,'sha256')
  from private.suspension_carryover_key k
$$;
revoke execute on function private.suspension_carryover_hash(text,text) from public,anon,authenticated,service_role;

-- ===== 2. suspension_set：接受指定的到期日 =====
-- p_duration 多一個 until（只有恢復停權用，p_until 是原本的到期日）；admin_set_user_suspension
-- 傳不了 p_until，所以這個值在管理站路徑一律被拒絕。其餘與
-- 202611052000_app_level_suspension.sql 相同。
drop function private.suspension_set(uuid,uuid,text,text,boolean);
create function private.suspension_set(p_actor uuid,p_user uuid,p_duration text,p_note text,
  p_extend_only boolean default false,p_until timestamptz default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_note text:=btrim(coalesce(p_note,''));
  v_old private.user_suspensions;
  v_active boolean;
  v_before timestamptz; v_after timestamptz;
  v_until timestamptz;
begin
  if p_actor is null or p_user is null or p_duration is null
     or p_duration not in ('7d','30d','indefinite','none','until') or char_length(v_note) not between 1 and 500
     or (p_duration='until' and (p_until is null or p_until<=now()))
     or (p_duration<>'until' and p_until is not null) then
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
    v_until:=case p_duration when '7d' then now()+interval '7 days' when '30d' then now()+interval '30 days'
      when 'until' then p_until end;
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
revoke execute on function private.suspension_set(uuid,uuid,text,text,boolean,timestamptz)
  from public,anon,authenticated,service_role;

-- ===== 3. 刪除帳號時寫入 =====
-- return old：BEFORE DELETE 回 null 會取消刪除。例外區塊內出錯不擋刪除；
-- warning 只記 SQLSTATE，不含身分資料。
create function public.suspension_carryover_capture() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_until timestamptz;
begin
  begin
    select s.until into v_until from private.user_suspensions s
      where s.user_id=old.id and (s.until is null or s.until>now());
    if found then
      insert into private.suspension_carryover(identity_hash,until,expires_at)
      select private.suspension_carryover_hash(i.provider,i.provider_id),v_until,
        coalesce(v_until,now()+private.retention_suspension_carryover())
      from auth.identities i
      where i.user_id=old.id and i.provider in ('google','apple')
      on conflict(identity_hash) do update set until=excluded.until,expires_at=excluded.expires_at,created_at=now();
    end if;
  exception when others then
    raise warning 'suspension_carryover_capture failed: %',sqlstate;
  end;
  return old;
end $$;
revoke execute on function public.suspension_carryover_capture() from public,anon,authenticated,service_role;
create trigger suspension_carryover_capture before delete on auth.users
  for each row execute function public.suspension_carryover_capture();

-- ===== 4. 同一身分重新建立帳號時恢復 =====
-- 例外區塊是子交易：出錯時刪列與停權一起復原。warning 只記 SQLSTATE，訊息
-- 內容不進紀錄。
create function public.suspension_carryover_restore() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_until timestamptz;
begin
  begin
    delete from private.suspension_carryover c
      where c.identity_hash=private.suspension_carryover_hash(new.provider,new.provider_id) and c.expires_at>now()
      returning c.until into v_until;
    if found then
      perform private.suspension_set(private.suspension_system_actor(),new.user_id,
        case when v_until is null then 'indefinite' else 'until' end,
        '同一登入身分重新建立帳號，恢復刪除前的停權（#331）',true,v_until);
    end if;
  exception when others then
    raise warning 'suspension_carryover_restore failed: %',sqlstate;
  end;
  return null;
end $$;
revoke execute on function public.suspension_carryover_restore() from public,anon,authenticated,service_role;
create trigger suspension_carryover_restore after insert on auth.identities
  for each row when (new.provider in ('google','apple'))
  execute function public.suspension_carryover_restore();

-- ===== 5. 到期清除 =====
create function public.suspension_carryover_prune() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  delete from private.suspension_carryover c where c.expires_at<=now();
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke execute on function public.suspension_carryover_prune() from public,anon,authenticated,service_role;

-- 其餘與 202611012100_account_data_retention.sql 相同。
create or replace function public.account_data_retention() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  return jsonb_build_object(
    'usage_events',public.usage_events_prune(),
    'anonymized_hashes',public.anonymized_hashes_clear(),
    'support_requests',public.support_requests_prune(),
    'suspension_carryover',public.suspension_carryover_prune(),
    'audit_log',public.admin_audit_deidentify());
end $$;
