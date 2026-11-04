-- #280 第 3 層：檢舉後立即暫時隱藏被檢舉的內容（使用者決定 PM_ANS_20261102_162、
-- _164；提案 t280-proposal.md 第 3、6 節）。管理員的期限 due_at 與有期限案件
-- 列表（timed_cases）等 #301 的 private.support_due_at 合併後再接。
--
-- 1. 範圍（HOLD_SCOPE_EXTRA＝A）：rider_name → 不顯示車友名稱（App 顯示「由車友
--    回報」，代號照回）；spot_name → 名稱換成「名稱審核中」；text → 備註、入口、
--    停哪裡、特殊規則清空；impersonation → 三者；other → 不立即隱藏、只進審核。
--    位置、能不能停、費率、格位照常（不隱藏整個點）。
-- 2. 做法：原文搬到 private.content_holds，點位上的欄位換成替代內容，所以每條
--    讀取路徑（view、viewport、nearby、spot_history、直接讀表）都只看到替代
--    內容；車友名稱由 spot_contributor_name() 判斷。community_spots.content_held
--    （公開）列出目前遮蔽的部分。投稿者本人（is_own）經 public_spots 看到原文，
--    仍回 content_held。遮蔽期間有人修改被遮蔽的欄位，新值也收進 holds，等管理員。
-- 3. 不立即隱藏（HOLD_ABUSE_RULES＝A，6 項全採；命中時 risk_flags 加
--    hold_skipped_<規則>）：rejected_reporter（90 天內被以 abuse／wrong 駁回的
--    檢舉 ≥2）、new_account（帳號未滿 24 小時）、reviewed_content（上次檢舉被
--    駁回後內容未變）、network_quota（同網路或同裝置 24 小時內已觸發 3 次）、
--    global_fuse（全站 24 小時內已立即隱藏 20 次；第一次觸發時寄信到 ops@）、
--    ip_busy（網路當天超過 200 筆）。
-- 4. 解除（HOLD_RELEASE＝A）：admin_v1.resolve_content_report 的 restore（駁回、
--    原文放回）、keep（維持隱藏或移除：名稱永久清除、點名改成管理員給的名稱、
--    文字移除）、edit（改內容後解除）；同一點同一 target 的處理中檢舉一起結案，
--    都寫 admin_audit_log。任何方式結案（含舊審核頁）時，沒有其他處理中的檢舉
--    遮蔽同一部分就解除。逾期維持隱藏。

-- ===== 1. 資料 =====
alter table public.community_spots add column content_held text[] not null default '{}'
  check (content_held <@ array['rider_name','spot_name','text']);
grant select (content_held) on public.community_spots to anon,authenticated;
comment on column public.community_spots.content_held is
  '檢舉後暫時遮蔽的部分（#280）：rider_name、spot_name、text；原文在 private.content_holds。';

-- 每一部分一列；original 是原文（spot_name：{name}；text：四個文字欄位；
-- rider_name：null，名稱跟著帳號）。
create table private.content_holds (
  spot_id uuid not null references public.community_spots(id) on delete cascade,
  part text not null check (part in ('rider_name','spot_name','text')),
  original jsonb,
  created_at timestamptz not null default now(),
  primary key (spot_id,part)
);
revoke all on private.content_holds from public,anon,authenticated,service_role;

-- 每筆檢舉的網路與裝置（同網路標記、network_quota），和這筆檢舉是否觸發遮蔽。
alter table public.moderation_queue add column held boolean not null default false;
create table private.content_report_identities (
  queue_id uuid primary key references public.moderation_queue(id) on delete cascade,
  ip_hash text not null,
  device_hash text not null,
  created_at timestamptz not null default now()
);
create index content_report_identities_ip_idx on private.content_report_identities(ip_hash,created_at);
create index content_report_identities_device_idx on private.content_report_identities(device_hash,created_at);
revoke all on private.content_report_identities from public,anon,authenticated,service_role;

create function private.content_hold_placeholder() returns text
language sql immutable set search_path='' as $$ select '名稱審核中' $$;
revoke execute on function private.content_hold_placeholder() from public,anon,authenticated,service_role;

create function private.content_text_fields() returns text[]
language sql immutable set search_path='' as $$ select array['note','entrance_note','parking_guide','special_rules'] $$;
revoke execute on function private.content_text_fields() from public,anon,authenticated,service_role;

-- target 遮蔽哪些部分。
create function private.content_hold_parts(p_target text) returns text[]
language sql immutable set search_path='' as $$
  select case p_target when 'rider_name' then array['rider_name'] when 'spot_name' then array['spot_name']
    when 'text' then array['text'] when 'impersonation' then array['rider_name','spot_name','text']
    else '{}'::text[] end
$$;
revoke execute on function private.content_hold_parts(text) from public,anon,authenticated,service_role;

-- ===== 2. 車友名稱 =====
-- 202611011930_account_deletion.sql 的規則，加上「車友名稱被遮蔽」。
create or replace function public.spot_contributor_name(p_spot uuid,p_user uuid,p_role text)
returns text language sql stable security invoker set search_path='' as $$
  select case when p_role<>'rider'
      or exists(select 1 from public.contributor_name_clears c where c.spot_id=p_spot)
      or exists(select 1 from private.account_deletion_requests r where r.user_id=p_user)
      or exists(select 1 from private.content_holds h where h.spot_id=p_spot and h.part='rider_name') then ''
    else coalesce((select public.contributor_display_name(u.raw_user_meta_data)
      from auth.users u where u.id=p_user and u.deleted_at is null),'') end;
$$;
revoke execute on function public.spot_contributor_name(uuid,uuid,text) from public,anon,authenticated,service_role;

-- ===== 3. 遮蔽與放回 =====
-- 遮蔽期間寫入被遮蔽的欄位：新值收進 holds，點位上維持替代內容。
create function public.community_spots_content_hold() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_f text; v_orig jsonb;
begin
  if cardinality(old.content_held)=0 or current_setting('app.content_hold',true)='1' then return new; end if;
  if 'spot_name'=any(old.content_held) and new.name is distinct from old.name then
    update private.content_holds h set original=jsonb_build_object('name',new.name)
      where h.spot_id=new.id and h.part='spot_name';
    new.name:=old.name;
  end if;
  if 'text'=any(old.content_held) then
    select h.original into v_orig from private.content_holds h where h.spot_id=new.id and h.part='text';
    foreach v_f in array private.content_text_fields() loop
      if (to_jsonb(new)->>v_f) is distinct from (to_jsonb(old)->>v_f) then
        v_orig:=coalesce(v_orig,'{}'::jsonb)||jsonb_build_object(v_f,to_jsonb(new)->v_f);
      end if;
    end loop;
    update private.content_holds h set original=v_orig where h.spot_id=new.id and h.part='text';
    new.note:=old.note; new.entrance_note:=old.entrance_note;
    new.parking_guide:=old.parking_guide; new.special_rules:=old.special_rules;
  end if;
  new.content_held:=old.content_held;
  return new;
end $$;
revoke execute on function public.community_spots_content_hold() from public,anon,authenticated,service_role;
create trigger community_spots_content_hold before update on public.community_spots
  for each row execute function public.community_spots_content_hold();

-- 遮蔽一個點的幾個部分（已遮蔽的不重做）。
create function private.content_hold_apply(p_spot uuid,p_parts text[]) returns void
language plpgsql security definer set search_path='' as $$
declare s public.community_spots; v_part text; v_new text[];
begin
  select * into s from public.community_spots where id=p_spot for update;
  v_new:=array(select x from unnest(p_parts) x where not x=any(s.content_held));
  if cardinality(v_new)=0 then return; end if;
  foreach v_part in array v_new loop
    insert into private.content_holds(spot_id,part,original) values(p_spot,v_part,case v_part
      when 'spot_name' then jsonb_build_object('name',s.name)
      when 'text' then jsonb_build_object('note',s.note,'entrance_note',s.entrance_note,
        'parking_guide',s.parking_guide,'special_rules',s.special_rules)
      end);
  end loop;
  perform set_config('app.content_hold','1',true);
  update public.community_spots c set
    content_held=array(select x from unnest(array['rider_name','spot_name','text']) x where x=any(c.content_held||v_new)),
    name=case when 'spot_name'=any(v_new) then private.content_hold_placeholder() else c.name end,
    note=case when 'text'=any(v_new) then '' else c.note end,
    entrance_note=case when 'text'=any(v_new) then '' else c.entrance_note end,
    parking_guide=case when 'text'=any(v_new) then '' else c.parking_guide end,
    special_rules=case when 'text'=any(v_new) then '' else c.special_rules end
    where c.id=p_spot;
  perform set_config('app.content_hold','',true);
end $$;
revoke execute on function private.content_hold_apply(uuid,text[]) from public,anon,authenticated,service_role;

-- 放回沒有處理中檢舉遮蔽的部分：原文（管理員 keep／edit 時已先改過 original）。
create function private.content_hold_release(p_spot uuid) returns text[]
language plpgsql security definer set search_path='' as $$
declare v_free text[]; r record;
begin
  select array_agg(h.part) into v_free from private.content_holds h where h.spot_id=p_spot
    and not exists(select 1 from public.moderation_queue q where q.source_id=p_spot::text and q.field='inappropriate'
      and q.held and q.resolved_at is null and h.part=any(private.content_hold_parts(q.proposed->>'target')));
  if v_free is null then return '{}'; end if;
  perform 1 from public.community_spots where id=p_spot for update;
  perform set_config('app.content_hold','1',true);
  for r in select * from private.content_holds x where x.spot_id=p_spot and x.part=any(v_free) loop
    if r.part='spot_name' then
      update public.community_spots c set name=coalesce(r.original->>'name',c.name) where c.id=p_spot;
    elsif r.part='text' then
      update public.community_spots c set note=coalesce(r.original->>'note',''),
        entrance_note=coalesce(r.original->>'entrance_note',''),parking_guide=coalesce(r.original->>'parking_guide',''),
        special_rules=coalesce(r.original->>'special_rules','') where c.id=p_spot;
    end if;
  end loop;
  delete from private.content_holds x where x.spot_id=p_spot and x.part=any(v_free);
  -- 這次 update 也讓觸發器重算車友名稱。
  update public.community_spots c set content_held=array(select x from unnest(c.content_held) x where not x=any(v_free))
    where c.id=p_spot;
  perform set_config('app.content_hold','',true);
  return v_free;
end $$;
revoke execute on function private.content_hold_release(uuid) from public,anon,authenticated,service_role;

-- ===== 4. 檢舉寫入時：防濫用規則與遮蔽 =====
-- 本人看到原文：只有投稿者本人、點位看得到時回原文。
create function public.spot_held_original(p_spot uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(h.part,h.original) filter (where h.original is not null),'{}'::jsonb)
    ||case when exists(select 1 from private.content_holds h where h.spot_id=p_spot and h.part='rider_name')
      then jsonb_build_object('contributor_name',coalesce((select case when exists(select 1 from public.contributor_name_clears c where c.spot_id=p_spot)
          or exists(select 1 from private.account_deletion_requests r where r.user_id=s.user_id) then ''
        else public.contributor_display_name(u.raw_user_meta_data) end
        from public.community_spots s join auth.users u on u.id=s.user_id where s.id=p_spot and u.deleted_at is null),''))
      else '{}'::jsonb end
  from private.content_holds h
  where h.spot_id=p_spot and public.spot_is_own(p_spot)
  having count(*)>0
$$;
revoke execute on function public.spot_held_original(uuid) from public;
grant execute on function public.spot_held_original(uuid) to anon,authenticated,service_role;

create function private.content_hold_skip(p_new public.moderation_queue,p_ip text,p_device text) returns text
language plpgsql stable security definer set search_path='' as $$
declare v_parts text[]:=private.content_hold_parts(p_new.proposed->>'target'); v_last public.moderation_queue;
  s public.community_spots; v_same boolean:=true; v_p text; v_cur jsonb;
begin
  if 'ip_busy'=any(p_new.risk_flags) then return 'ip_busy'; end if;
  if (select count(*) from public.moderation_queue q where q.reporter_id=p_new.reporter_id and q.field='inappropriate'
      and q.status='rejected' and q.resolution_kind in ('abuse','wrong') and q.resolved_at>now()-interval '90 days')>=2 then
    return 'rejected_reporter';
  end if;
  if exists(select 1 from auth.users u where u.id=p_new.reporter_id and u.created_at>now()-interval '24 hours') then
    return 'new_account';
  end if;
  -- 上次遮蔽同一部分的檢舉被駁回後，這些部分沒變：等人工審核。
  select * into v_last from public.moderation_queue q where q.source_id=p_new.source_id and q.field='inappropriate'
    and q.status='rejected' and private.content_hold_parts(q.proposed->>'target') && v_parts
    order by q.resolved_at desc limit 1;
  if v_last.id is not null then
    select * into s from public.community_spots where id=p_new.source_id::uuid;
    v_cur:=to_jsonb(s)||coalesce((select jsonb_object_agg(k,v) from private.content_holds h,jsonb_each(h.original) e(k,v)
      where h.spot_id=s.id),'{}'::jsonb);
    foreach v_p in array v_parts loop
      if v_p='rider_name' then
        v_same:=v_same and (v_last.base_spot->>'contributor_name') is not distinct from
          public.spot_contributor_name(s.id,s.user_id,s.contributor_role);
      elsif v_p='spot_name' then
        v_same:=v_same and (v_last.base_spot->>'name') is not distinct from (v_cur->>'name');
      else
        v_same:=v_same and not exists(select 1 from unnest(private.content_text_fields()) f
          where (v_last.base_spot->>f) is distinct from (v_cur->>f));
      end if;
    end loop;
    if v_same then return 'reviewed_content'; end if;
  end if;
  if (select count(*) from private.content_report_identities i join public.moderation_queue q on q.id=i.queue_id
      where q.held and i.created_at>now()-interval '24 hours' and (i.ip_hash=p_ip or i.device_hash=p_device))>=3 then
    return 'network_quota';
  end if;
  if (select count(*) from public.moderation_queue q where q.held and q.field='inappropriate'
      and q.created_at>now()-interval '24 hours')>=20 then
    return 'global_fuse';
  end if;
  return null;
end $$;
revoke execute on function private.content_hold_skip(public.moderation_queue,text,text) from public,anon,authenticated,service_role;

-- BEFORE：在 moderation_inappropriate_check（名稱較前）之後依名稱執行。
create function public.moderation_inappropriate_hold() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_skip text;
begin
  -- 快照是原文，不是替代內容（遮蔽期間送來的任何回報）。
  if new.base_spot is not null and new.source_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and exists(select 1 from private.content_holds h where h.spot_id=new.source_id::uuid) then
    new.base_spot:=new.base_spot||coalesce((select jsonb_object_agg(e.k,e.v) from private.content_holds h,
        jsonb_each(h.original) e(k,v) where h.spot_id=new.source_id::uuid),'{}'::jsonb)
      ||coalesce((select jsonb_build_object('contributor_name',coalesce(public.contributor_display_name(u.raw_user_meta_data),''))
        from public.community_spots s join auth.users u on u.id=s.user_id
        where s.id=new.source_id::uuid and s.contributor_role='rider' and u.deleted_at is null
          and exists(select 1 from private.content_holds h where h.spot_id=s.id and h.part='rider_name')
          and not exists(select 1 from public.contributor_name_clears c where c.spot_id=s.id)
          and not exists(select 1 from private.account_deletion_requests r where r.user_id=s.user_id)),'{}'::jsonb);
  end if;
  if new.field is distinct from 'inappropriate' then return new; end if;
  if cardinality(private.content_hold_parts(new.proposed->>'target'))=0 then return new; end if;
  v_skip:=private.content_hold_skip(new,nullif(current_setting('app.report_ip',true),''),
    nullif(current_setting('app.report_device',true),''));
  if v_skip is null then
    new.held:=true;
  else
    new.risk_flags:=array_append(new.risk_flags,'hold_skipped_'||v_skip);
  end if;
  return new;
end $$;
revoke execute on function public.moderation_inappropriate_hold() from public,anon,authenticated,service_role;
create trigger moderation_inappropriate_hold before insert on public.moderation_queue
  for each row execute function public.moderation_inappropriate_hold();

-- AFTER：記下網路與裝置、遮蔽，保險絲第一次觸發時通知。
create function public.moderation_inappropriate_after() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_ip text:=nullif(current_setting('app.report_ip',true),'');
  v_device text:=nullif(current_setting('app.report_device',true),'');
begin
  if new.field is distinct from 'inappropriate' then return null; end if;
  if v_ip is not null and v_device is not null then
    insert into private.content_report_identities(queue_id,ip_hash,device_hash) values(new.id,v_ip,v_device)
    on conflict do nothing;
  end if;
  if new.held then
    perform private.content_hold_apply(new.source_id::uuid,private.content_hold_parts(new.proposed->>'target'));
  end if;
  if 'hold_skipped_global_fuse'=any(new.risk_flags) and not exists(select 1 from private.report_notices n
      where n.kind='fuse' and n.created_at>now()-interval '24 hours') then
    insert into private.report_notices(queue_id,kind) values(new.id,'fuse') on conflict do nothing;
  end if;
  return null;
end $$;
revoke execute on function public.moderation_inappropriate_after() from public,anon,authenticated,service_role;
create trigger moderation_inappropriate_after after insert on public.moderation_queue
  for each row execute function public.moderation_inappropriate_after();

-- 任何方式結案（含舊審核頁 admin_resolve_report）：放回沒有其他處理中檢舉遮蔽的部分。
create function public.moderation_inappropriate_resolved() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.field='inappropriate' and new.held and old.resolved_at is null and new.resolved_at is not null then
    perform private.content_hold_release(new.source_id::uuid);
  end if;
  return null;
end $$;
revoke execute on function public.moderation_inappropriate_resolved() from public,anon,authenticated,service_role;
create trigger moderation_inappropriate_resolved after update on public.moderation_queue
  for each row execute function public.moderation_inappropriate_resolved();

-- 通知分種類：new（每筆新檢舉）、fuse（全站保險絲）。
alter table private.report_notices add column kind text not null default 'new' check (kind in ('new','fuse'));
alter table private.report_notices drop constraint report_notices_pkey, add primary key (queue_id,kind);
drop function public.report_mail_pending(int);
create function public.report_mail_pending(p_limit int default 50) returns table(id uuid,kind text)
language sql stable security definer set search_path='' as $$
  select n.queue_id,n.kind from private.report_notices n where n.sent_at is null
  order by n.created_at limit least(greatest(coalesce(p_limit,50),1),200)
$$;
revoke execute on function public.report_mail_pending(int) from public,anon,authenticated;
grant execute on function public.report_mail_pending(int) to service_role;
drop function public.report_mail_sent(uuid);
create function public.report_mail_sent(p_id uuid,p_kind text default 'new') returns void
language sql security definer set search_path='' as $$
  update private.report_notices set sent_at=now() where queue_id=p_id and kind=p_kind and sent_at is null;
  delete from private.report_notices where sent_at<now()-interval '30 days';
$$;
revoke execute on function public.report_mail_sent(uuid,text) from public,anon,authenticated;
grant execute on function public.report_mail_sent(uuid,text) to service_role;

-- ===== 5. apply_report：把網路與裝置交給觸發器 =====
-- 其餘與 202611012100_account_data_retention.sql 相同。
CREATE OR REPLACE FUNCTION public.apply_report(p_user uuid, p_ip text, p_device text, p_payload jsonb, p_ip_capped boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_action text:=p_payload->>'action'; v_spot jsonb:=p_payload->'spot';
  v_id uuid; v_existing uuid; v_owner uuid; v_qualified boolean; v_score numeric; v_count integer; v_decided timestamptz;
  -- The day resets at midnight in Taiwan (#203).
  v_day timestamptz:=public.report_day_start();
  v_ip_busy boolean:=false;
  -- Precheck holds (submit-report sets them, never the client) and the
  -- notice a rider attaches as evidence (design §4.2, §4.3, §1.4).
  v_flags text[]:=array(select jsonb_array_elements_text(
    case when jsonb_typeof(p_payload->'risk_flags')='array' then p_payload->'risk_flags' else '[]'::jsonb end));
  v_evidence text:=nullif(btrim(coalesce(p_payload->>'evidence_url','')),'');
  v_need integer;
begin
  if p_ip is null or char_length(p_ip)<>64 or p_device is null or char_length(p_device)<>64 then
    raise exception 'missing trusted identity' using errcode='22023';
  end if;
  if not exists(select 1 from auth.users u join auth.identities i on i.user_id=u.id
      where u.id=p_user and not u.is_anonymous and i.provider in ('google','apple')) then
    raise exception 'Google or Apple sign-in required' using errcode='42501';
  end if;
  select created_at<=now()-interval '7 days' into v_qualified from auth.users where id=p_user;
  -- Order is always IP then account: serializes competing requests without deadlocks.
  perform pg_advisory_xact_lock(hashtextextended('ip:'||p_ip,0));
  perform pg_advisory_xact_lock(hashtextextended('user:'||p_user::text,0));
  -- 10 a day per account. Per network 200 a day while App Check only logs
  -- (p_ip_capped); once it is enforced the network count is a risk signal
  -- instead: past 200 the report is kept, marked ip_busy, and goes to review
  -- or weighs less (#203).
  if (select count(*) from rate_limit_events where user_id=p_user and created_at>=v_day)>=10 then
    raise exception 'daily report limit reached' using errcode='P0001';
  end if;
  if (select count(*) from rate_limit_events where ip_hash=p_ip and created_at>=v_day)>=200 then
    if p_ip_capped is not false then
      raise exception 'daily report limit reached' using errcode='P0001';
    end if;
    v_ip_busy:=true;
    -- A new spot opens a case and needs one more confirmation; a flag
    -- carries the signal to the reviewer.
    v_flags:=array_append(v_flags,'ip_busy');
  end if;
  insert into rate_limit_events(user_id,ip_hash,ip_busy) values(p_user,p_ip,v_ip_busy);
  if v_action='create' then
    -- One lock per space type prevents duplicate inserts racing from separate IPs.
    perform pg_advisory_xact_lock(hashtextextended('create:'||(v_spot->>'space_type'),0));
    select id into v_existing from community_spots where status<>'hidden' and space_type=v_spot->>'space_type'
      and extensions.st_dwithin(location,extensions.st_setsrid(extensions.st_makepoint((v_spot->>'lng')::float8,(v_spot->>'lat')::float8),4326)::extensions.geography,15) limit 1;
    if v_existing is not null then return jsonb_build_object('duplicate_id',v_existing);end if;
    -- A rider attaches a notice to a report as evidence; only admins and
    -- imports write a condition's basis (§1.4). validate.ts refuses it first.
    if v_spot->'condition' ? 'basis' or exists(select 1 from jsonb_array_elements(
        case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end
        || case when jsonb_typeof(v_spot->'parking_segments')='array' then v_spot->'parking_segments' else '[]'::jsonb end) z
        where z->'condition' ? 'basis') then
      raise exception 'a report cannot set a condition basis' using errcode='22023';
    end if;
    -- Both vehicles stated (#201): a street spot true or false, a lot also
    -- not_stated; every zone it adds states both. validate.ts refuses the
    -- rest first.
    if not public.eligibility_values_ok(v_spot) or not public.eligibility_stated(v_spot)
       or ((v_spot->>'scooter_not_stated')::boolean or (v_spot->>'heavy_not_stated')::boolean)
         and not public.condition_off_street(v_spot->>'space_type',coalesce(v_spot->>'facility_type',v_spot->'facility_types'->>0))
       or exists(select 1 from jsonb_array_elements(
         case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end) z
         where not public.zone_eligibility_stated(z)) then
      raise exception 'a new spot states both vehicles' using errcode='22023';
    end if;
    insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,fee,
        facility_type,facility_types,parking_access,entrance_note,parking_guide,parking_zones,parking_segments,condition)
    values(p_user,btrim(v_spot->>'name'),(v_spot->>'lat')::float8,(v_spot->>'lng')::float8,v_spot->>'city',coalesce(v_spot->>'district',''),v_spot->>'space_type',coalesce(v_spot->>'fee_note','請依現場公告'),coalesce(v_spot->>'note',''),(v_spot->>'scooter_allowed')::boolean,(v_spot->>'heavy_allowed')::boolean,
      coalesce((v_spot->>'scooter_not_stated')::boolean,false),coalesce((v_spot->>'heavy_not_stated')::boolean,false),
      case when jsonb_typeof(v_spot->'fee')='object' then v_spot->'fee' end,
      -- Lot details: how the lot is built, who parks where, how to get in and
      -- park, and its zones; submit-report/validate.ts checks their shape.
      nullif(v_spot->>'facility_type',''),
      case when jsonb_typeof(v_spot->'facility_types')='array'
        then array(select jsonb_array_elements_text(v_spot->'facility_types')) end,
      nullif(v_spot->>'parking_access',''),
      btrim(coalesce(v_spot->>'entrance_note','')),btrim(coalesce(v_spot->>'parking_guide','')),
      case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end,
      -- A street spot's segments (#188); the trigger gives zones and
      -- segments their ids.
      case when jsonb_typeof(v_spot->'parking_segments')='array' then v_spot->'parking_segments' else '[]'::jsonb end,
      -- The bay's condition; the table check holds it to the contract and
      -- to space_type. Builds without it send none and store null.
      case when jsonb_typeof(v_spot->'condition')='object' then v_spot->'condition' end) returning id into v_id;
    insert into report_identities values(v_id,p_ip,p_device);
    -- A held spot, or one with a notice attached, opens a case so an admin
    -- sees the flags and the link; while it is open, confirming the spot
    -- takes one more vote (feasibility §5.8).
    if cardinality(v_flags)>0 or v_evidence is not null then
      insert into moderation_queue(source_id,reporter_id,reason,field,risk_flags,evidence_url)
      values(v_id::text,p_user,'新增停車點：預檢暫留或附公告連結','create',v_flags,v_evidence)
      on conflict do nothing;
    end if;
  elsif v_action='vote' then
    v_id:=(p_payload->>'spot_id')::uuid;
    if public.spot_deleted(v_id::text) then raise exception 'spot deleted' using errcode='P0410'; end if;
    select user_id into v_owner from community_spots where id=v_id and status<>'hidden' for update;
    -- Found by the row, not its owner: a deleted account's spot has none (#215).
    if not found then raise exception 'spot not found' using errcode='22023';end if;
    if v_owner=p_user then raise exception 'cannot confirm own report' using errcode='42501';end if;
    if exists(select 1 from report_identities where spot_id=v_id and (ip_hash=p_ip or device_hash=p_device)) then v_qualified:=false;end if;
    -- A vote from a busy network weighs as an unqualified one (#203).
    if v_ip_busy then v_qualified:=false; end if;
    insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
      values(v_id,p_user,p_payload->>'vote',v_qualified,case when v_qualified then 1 else 0.25 end,p_ip,p_device)
      on conflict(spot_id,user_id) do update set vote=excluded.vote,qualified=excluded.qualified,weight=excluded.weight,ip_hash=excluded.ip_hash,device_hash=excluded.device_hash,created_at=now();
    -- Distinct IP AND device, and two qualified users. Network/device sameness cannot inflate confirmations.
    -- count(distinct) skips the votes whose hashes were cleared (#267).
    select least(count(distinct ip_hash),count(distinct device_hash)) into v_count from spot_votes where spot_id=v_id and vote='still_there' and qualified;
    -- A spot created under a hold needs one more confirmation until an
    -- admin resolves its case (feasibility §5.8, decision 17).
    -- Only the spot's own creation counts: a held suggestion is not applied
    -- yet and must not shake the spot's standing.
    v_need:=2+case when exists(select 1 from moderation_queue where source_id=v_id::text
      and field='create' and resolved_at is null and cardinality(risk_flags)>0) then 1 else 0 end;
    -- Once an admin has decided a dispute, the "gone" votes before that
    -- decision are spent: only later ones can reopen it.
    select max(resolved_at) into v_decided from moderation_queue
      where source_id=v_id::text and reason='加權負向回報達門檻' and status<>'pending';
    -- A vote whose hashes were cleared 180 days after its account was
    -- deleted belongs to no network: left out, never merged into one (#267).
    select coalesce(sum(weight),0) into v_score from(select max(weight) as weight from spot_votes where spot_id=v_id and vote='gone'
      and ip_hash is not null
      and created_at>coalesce(v_decided,'-infinity') group by ip_hash) x;
    if v_score>=3 then
      -- Votes alone never take a spot off the map: it drops back to pending
      -- (unverified everywhere) and waits for an admin to hide or keep it.
      update community_spots set status='pending',updated_at=now() where id=v_id;
      insert into moderation_queue(source_id,reason) values(v_id::text,'加權負向回報達門檻') on conflict do nothing;
    else
      -- Only a qualified "still there" is a fresh sighting; other votes keep
      -- the last confirmation time.
      -- A spot an admin kept after a dispute stays confirmed; only a new
      -- dispute can demote it.
      update community_spots set status=case when v_count>=v_need or (status='confirmed' and v_decided is not null) then 'confirmed' else 'pending' end,
        last_confirmed_at=case when v_count>=v_need and p_payload->>'vote'='still_there' and v_qualified then now() else last_confirmed_at end,
        updated_at=now() where id=v_id;
    end if;
  elsif v_action='flag' then
    if public.spot_deleted(p_payload->>'source_id') then raise exception 'spot deleted' using errcode='P0410'; end if;
    -- The network and device the hold rules read (#280); this transaction only.
    perform set_config('app.report_ip',p_ip,true);
    perform set_config('app.report_device',p_device,true);
    insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note,risk_flags,evidence_url)
    values(p_payload->>'source_id',p_user,p_payload->>'reason',nullif(btrim(coalesce(p_payload->>'field','')),''),
      case when jsonb_typeof(p_payload->'proposed')='object' then p_payload->'proposed' end,
      coalesce(p_payload->>'note',''),v_flags,v_evidence)
    on conflict do nothing;
  elsif v_action in ('update','delete') then
    v_id:=(p_payload->>'spot_id')::uuid;
    select user_id into v_owner from community_spots where id=v_id for update;
    if v_owner is distinct from p_user then raise exception 'only owner can edit' using errcode='42501';end if;
    -- Deleted by an admin: the owner can neither restore nor change it.
    if public.spot_deleted(v_id::text) then raise exception 'spot deleted' using errcode='P0410'; end if;
    if v_action='delete' then delete from community_spots where id=v_id;
    else
      -- Edit history (decision 56): the trigger records this update as the
      -- owner's own edit (車友更新).
      perform set_config('app.owner_update',v_id::text,true);
      update community_spots set name=btrim(v_spot->>'name'),fee_note=coalesce(v_spot->>'fee_note',fee_note),note=coalesce(v_spot->>'note',note),status='pending',last_confirmed_at=null,updated_at=now() where id=v_id;
      delete from spot_votes where spot_id=v_id;
    end if;
  else raise exception 'invalid report action' using errcode='22023';
  end if;
  return jsonb_build_object('id',v_id,'accepted',true);
end;
$function$;
revoke all on function public.apply_report(uuid,text,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.apply_report(uuid,text,text,jsonb,boolean) to service_role;

-- ===== 6. public_spots：本人看原文 =====
-- 202611021000_contributor_handle.sql 的 view；被遮蔽的點，投稿者本人看到原文，
-- 最後加 content_held。
create or replace view public.public_spots with (security_invoker=true) as
  select c.id,c.source,c.source_name,c.source_url,c.license_note,coalesce(o.orig->'spot_name'->>'name',c.name) as name,
    c.lat,c.lng,c.city,c.district,c.space_type,c.fee_note,coalesce(o.orig->'text'->>'note',c.note) as note,
    c.scooter_total,c.available,c.scooter_allowed,c.heavy_allowed,c.status,c.updated_at,c.last_confirmed_at,c.created_at,
    c.facility_type,c.parking_access,c.address,c.road_segment,coalesce(o.orig->'text'->>'entrance_note',c.entrance_note) as entrance_note,
    coalesce(o.orig->'text'->>'parking_guide',c.parking_guide) as parking_guide,
    coalesce(o.orig->'text'->>'special_rules',c.special_rules) as special_rules,
    c.photo_urls,c.parking_zones,c.fee,coalesce(o.orig->>'contributor_name',c.contributor_name) as contributor_name,
    c.contributor_role,c.scooter_verified_at,c.heavy_verified_at,
    c.condition,c.zones_complete,c.closure,public.closure_state(c.closure) as closure_state,c.facility_types,c.parking_segments,
    c.scooter_not_stated,c.heavy_not_stated,
    public.spot_contributor_handle(c.id) as contributor_handle,
    public.spot_is_own(c.id) as is_own,
    c.content_held
  from public.community_spots c
  left join lateral (select public.spot_held_original(c.id) as orig where cardinality(c.content_held)>0) o on true
  where c.deleted_at is null;

-- ===== 7. 管理站：檢舉詳情與處理 =====
-- 點位目前的原文（遮蔽中的部分取 holds）。
create function private.spot_admin_content(p_spot uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('name',s.name,'note',s.note,'entrance_note',s.entrance_note,
      'parking_guide',s.parking_guide,'special_rules',s.special_rules,'contributor_name',s.contributor_name)
    ||coalesce((select jsonb_object_agg(e.k,e.v) from private.content_holds h,jsonb_each(h.original) e(k,v)
      where h.spot_id=s.id),'{}'::jsonb)
    ||case when 'rider_name'=any(s.content_held) then jsonb_build_object('contributor_name',
        coalesce((select case when exists(select 1 from public.contributor_name_clears c where c.spot_id=s.id)
            or exists(select 1 from private.account_deletion_requests r where r.user_id=s.user_id) then ''
          else public.contributor_display_name(u.raw_user_meta_data) end
          from auth.users u where u.id=s.user_id and u.deleted_at is null),'')) else '{}'::jsonb end
  from public.community_spots s where s.id=p_spot
$$;
revoke execute on function private.spot_admin_content(uuid) from public,anon,authenticated,service_role;

create function private.content_editable_fields() returns text[]
language sql immutable set search_path='' as $$ select array['name','note','entrance_note','parking_guide','special_rules'] $$;
revoke execute on function private.content_editable_fields() from public,anon,authenticated,service_role;

-- 讀一筆檢舉：同一點、同一 target、處理中的檢舉合成一組（每一則的時間、
-- 附註、是否和組內其他檢舉同網路）。只回結構化欄位，不回中文句子。
create function admin_v1.content_report(p_id text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare q public.moderation_queue; s public.community_spots;
begin
  perform private.require_admin();
  if p_id is null or p_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_id"}';
  end if;
  select * into q from public.moderation_queue m where m.id=p_id::uuid and m.field='inappropriate';
  if q.id is null then raise sqlstate 'PT404' using message='content_report.not_found'; end if;
  select * into s from public.community_spots c where c.id=q.source_id::uuid;
  return jsonb_build_object(
    'id',q.id::text,'status',q.status,'spot_id',q.source_id,'target',q.proposed->>'target',
    'created_at',q.created_at,'spot_updated_at',s.updated_at,'spot_deleted',s.id is null or s.deleted_at is not null,
    'content_held',coalesce(to_jsonb(s.content_held),'[]'::jsonb),
    'snapshot',jsonb_build_object('name',q.base_spot->'name','contributor_name',q.base_spot->'contributor_name',
      'note',q.base_spot->'note','entrance_note',q.base_spot->'entrance_note',
      'parking_guide',q.base_spot->'parking_guide','special_rules',q.base_spot->'special_rules'),
    'current',private.spot_admin_content(s.id),
    'editable_fields',to_jsonb(private.content_editable_fields()),
    'reports',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id::text,'created_at',m.created_at,'note',m.note,
        'held',m.held,'risk_flags',to_jsonb(m.risk_flags),
        'same_network',exists(select 1 from private.content_report_identities a join private.content_report_identities b
          on b.ip_hash=a.ip_hash and b.queue_id<>a.queue_id join public.moderation_queue o on o.id=b.queue_id
          where a.queue_id=m.id and o.source_id=m.source_id and o.field='inappropriate'
            and o.proposed->>'target'=m.proposed->>'target' and o.resolved_at is null))
        order by m.created_at),'[]'::jsonb)
      from public.moderation_queue m where m.source_id=q.source_id and m.field='inappropriate'
        and m.proposed->>'target'=q.proposed->>'target'
        and (m.id=q.id or (q.resolved_at is null and m.resolved_at is null))));
end $$;
revoke execute on function admin_v1.content_report(text) from public;
grant execute on function admin_v1.content_report(text) to authenticated;

-- 處理：restore（駁回、原文放回；p_reason 用既有駁回原因）、keep（維持隱藏或
-- 移除：車友名稱永久清除、點名改成 p_patch.name、文字移除，p_patch 可另給
-- 文字）、edit（以 p_patch 改內容後解除）。同一點、同一 target 的處理中檢舉
-- 一起結案。點位在 p_expected_updated_at 之後被改過時 PT409 content_report.stale。
create function admin_v1.resolve_content_report(p_id text,p_action text,p_expected_updated_at timestamptz,
  p_patch jsonb default null,p_reason text default null,p_note text default '')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  q public.moderation_queue; s public.community_spots;
  v_note text:=btrim(coalesce(p_note,''));
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_parts text[]; v_ids uuid[]; v_before jsonb; v_after jsonb; v_status text; v_final jsonb:='{}'::jsonb;
begin
  perform private.require_admin();
  if p_id is null or p_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_action is null or p_action not in ('restore','keep','edit') or p_expected_updated_at is null
     or char_length(v_note)>500 then
    raise sqlstate 'PT400' using message='request.invalid';
  end if;
  -- 只接受五個文字欄位、非空字串；點名 1–100 字，其他最多 500 字。
  if jsonb_typeof(v_patch)<>'object'
     or exists(select 1 from jsonb_each(v_patch) e where not e.key=any(private.content_editable_fields())
       or jsonb_typeof(e.value)<>'string' or btrim(e.value#>>'{}')=''
       or char_length(e.value#>>'{}')>case when e.key='name' then 100 else 500 end)
     or (p_action='restore' and v_patch<>'{}'::jsonb)
     or (p_action='edit' and v_patch='{}'::jsonb) then
    raise sqlstate 'PT400' using message='content_report.invalid_patch';
  end if;
  if p_action='restore' and (p_reason is null or p_reason not in ('wrong','duplicate','insufficient','outdated','abuse','other')
     or (p_reason='other' and v_note='')) then
    raise sqlstate 'PT400' using message='content_report.reason_required';
  end if;
  if p_action<>'restore' and p_reason is not null then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_reason"}';
  end if;
  select * into q from public.moderation_queue m where m.id=p_id::uuid and m.field='inappropriate' for update;
  if q.id is null then raise sqlstate 'PT404' using message='content_report.not_found'; end if;
  if q.resolved_at is not null then raise sqlstate 'PT409' using message='content_report.already_resolved'; end if;
  select * into s from public.community_spots c where c.id=q.source_id::uuid for update;
  if s.id is null then raise sqlstate 'PT404' using message='content_report.spot_not_found'; end if;
  if s.updated_at is distinct from p_expected_updated_at then
    raise sqlstate 'PT409' using message='content_report.stale',
      detail=jsonb_build_object('updated_at',s.updated_at)::text;
  end if;
  v_parts:=private.content_hold_parts(q.proposed->>'target');
  if p_action='keep' and 'spot_name'=any(v_parts) and not v_patch ? 'name' then
    raise sqlstate 'PT400' using message='content_report.name_required';
  end if;
  v_before:=private.spot_admin_content(s.id)||jsonb_build_object('content_held',to_jsonb(s.content_held));
  v_status:=case when p_action='restore' then 'rejected' else 'accepted' end;
  select array_agg(m.id) into v_ids from public.moderation_queue m where m.source_id=q.source_id
    and m.field='inappropriate' and m.resolved_at is null and m.proposed->>'target'=q.proposed->>'target';
  -- 結案（觸發器放回沒有其他檢舉遮蔽的部分）。
  update public.moderation_queue m set status=v_status,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note,
    resolution_kind=case when p_action='restore' then p_reason end
    where m.id=any(v_ids);
  if p_action='keep' then
    if 'text'=any(v_parts) then
      v_final:=jsonb_build_object('note','','entrance_note','','parking_guide','','special_rules','');
    end if;
    if 'rider_name'=any(v_parts) then
      insert into public.contributor_name_clears(spot_id,cleared_by,note) values(s.id,auth.uid(),left(v_note,500))
      on conflict (spot_id) do nothing;
    end if;
  end if;
  v_final:=v_final||v_patch;
  -- 還被其他檢舉遮蔽的部分，新值由 community_spots_content_hold 收進 holds。
  update public.community_spots c set
    name=coalesce(v_final->>'name',c.name),note=coalesce(v_final->>'note',c.note),
    entrance_note=coalesce(v_final->>'entrance_note',c.entrance_note),
    parking_guide=coalesce(v_final->>'parking_guide',c.parking_guide),
    special_rules=coalesce(v_final->>'special_rules',c.special_rules),
    updated_at=case when v_final<>'{}'::jsonb or (p_action='keep' and 'rider_name'=any(v_parts)) then now() else c.updated_at end
    where c.id=s.id;
  select * into s from public.community_spots c where c.id=s.id;
  v_after:=private.spot_admin_content(s.id)||jsonb_build_object('content_held',to_jsonb(s.content_held));
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'resolve_content_report','community_spots',s.id::text,
      v_before||jsonb_build_object('reports',to_jsonb(v_ids)),
      v_after||jsonb_build_object('action',p_action,'status',v_status,'reason',p_reason),v_note);
  return jsonb_build_object('status',v_status,'resolved_count',cardinality(v_ids),
    'spot',v_after||jsonb_build_object('id',s.id::text,'updated_at',s.updated_at));
end $$;
revoke execute on function admin_v1.resolve_content_report(text,text,timestamptz,jsonb,text,text) from public;
grant execute on function admin_v1.resolve_content_report(text,text,timestamptz,jsonb,text,text) to authenticated;
