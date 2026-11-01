-- 刪除帳號（#215；使用者決定 2026-11-01）：
--   * 社群貢獻（新增的點位、修改建議與檢舉、投票、目擊回報）保留內容、
--     改成匿名：只拿掉和帳號的連結與顯示名稱。
--   * 審核中的回報保留並匿名，照常審核。
--   * 7 天冷靜期：申請後 7 天內可以取消，到期才真的刪除。
--
-- 1. 外鍵：匿名保留的表改成 on delete set null，個人資料改成 cascade，
--    之後刪 auth.users 一次就由資料庫完成全部匿名與刪除；點位上的
--    顯示名稱快照由既有的 community_spots_contributor 觸發器清成空字串。
-- 2. 申請、取消、查詢：api_v1 的三支 RPC，申請要近期重新登入（JWT amr）。
-- 3. 到期執行：pg_cron 每日呼叫 Edge Function account-deletion（service
--    role），它用 Storage API 刪頭像（SQL 不能刪 Storage 物件）、再以
--    auth.admin.deleteUser 刪帳號。
-- 4. 稽核：private.account_deletion_audit 只存隨機的申請編號、事件與筆數，
--    不存 user_id、名稱或 email。
-- 5. 待決題答案（PM_ANS_20261101_112）：管理員不能自助刪除（要先由別的
--    管理員移除權限）；申請後立刻停止公開顯示名稱，取消時恢復；冷靜期內
--    新的登入（auth.sessions 新增一列）自動取消申請。

-- ===== 1. 外鍵 =====
alter table public.community_spots alter column user_id drop not null,
  drop constraint community_spots_user_id_fkey,
  add constraint community_spots_user_id_fkey foreign key (user_id)
    references auth.users(id) on delete set null;

-- 投票：主鍵 (spot_id,user_id) 容不下匿名票，改用流水號；每人每點一票
-- 改由 unique 約束保證（null 彼此不衝突，on conflict (spot_id,user_id) 照用）。
alter table public.spot_votes drop constraint spot_votes_pkey;
alter table public.spot_votes add column id bigint generated always as identity primary key;
alter table public.spot_votes alter column user_id drop not null,
  add constraint spot_votes_spot_id_user_id_key unique (spot_id,user_id),
  drop constraint spot_votes_user_id_fkey,
  add constraint spot_votes_user_id_fkey foreign key (user_id)
    references auth.users(id) on delete set null;

alter table public.moderation_queue
  drop constraint moderation_queue_reporter_id_fkey,
  add constraint moderation_queue_reporter_id_fkey foreign key (reporter_id)
    references auth.users(id) on delete set null;

-- 匿名化的時間（#267 從這天起算保留期，例如保留的雜湊 180 天後清除）。
-- 帳號刪除時外鍵把使用者欄位設為 null，觸發器同時記下時間；
-- moderation_queue 也靠它分辨「回報者已刪帳號」與「投票自動建立」。
alter table public.community_spots add column anonymized_at timestamptz;
alter table public.spot_votes add column anonymized_at timestamptz;
alter table public.moderation_queue add column anonymized_at timestamptz;
alter table public.rider_sightings add column anonymized_at timestamptz;
comment on column public.community_spots.anonymized_at is '回報者刪除帳號、user_id 清除的時間（#215）；report_identities 的雜湊從這天起算保留期（#267）。';
comment on column public.spot_votes.anonymized_at is '投票者刪除帳號、user_id 清除的時間（#215）；ip_hash／device_hash 從這天起算保留期（#267）。';
comment on column public.moderation_queue.anonymized_at is '回報者刪除帳號、reporter_id 清除的時間（#215）。';
comment on column public.rider_sightings.anonymized_at is '回報者刪除帳號、user_id 清除的時間（#215）。';

-- tg_argv[0]：使用者欄位。由有值變成 null 時記下匿名化時間。
create function public.mark_anonymized() returns trigger
language plpgsql set search_path='' as $$
begin
  if (to_jsonb(old)->>tg_argv[0]) is not null and (to_jsonb(new)->>tg_argv[0]) is null
     and new.anonymized_at is null then
    new:=jsonb_populate_record(new,jsonb_build_object('anonymized_at',now()));
  end if;
  return new;
end $$;
revoke execute on function public.mark_anonymized() from public,anon,authenticated;
create trigger community_spots_anonymized before update of user_id on public.community_spots
  for each row execute function public.mark_anonymized('user_id');
create trigger spot_votes_anonymized before update of user_id on public.spot_votes
  for each row execute function public.mark_anonymized('user_id');
create trigger moderation_queue_anonymized before update of reporter_id on public.moderation_queue
  for each row execute function public.mark_anonymized('reporter_id');
create trigger rider_sightings_anonymized before update of user_id on public.rider_sightings
  for each row execute function public.mark_anonymized('user_id');

-- 目擊回報匿名保留（原本 cascade）。評分只看 user_id<>p_user 的列，
-- null 不會被加分；可信度分數表照舊 cascade 刪除。
alter table public.rider_sightings alter column user_id drop not null,
  drop constraint rider_sightings_user_id_fkey,
  add constraint rider_sightings_user_id_fkey foreign key (user_id)
    references auth.users(id) on delete set null;

-- 限流紀錄是個人資料，跟著帳號刪除。
alter table public.rate_limit_events
  drop constraint rate_limit_events_user_id_fkey,
  add constraint rate_limit_events_user_id_fkey foreign key (user_id)
    references auth.users(id) on delete cascade;

-- 匿名化的點位沒有 user_id：投票改以「找到點位」判斷，不能再用
-- 「user_id 是 null」當作找不到。其餘與 202611010350_report_limits_taipei_day.sql 相同。
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
    select coalesce(sum(weight),0) into v_score from(select max(weight) as weight from spot_votes where spot_id=v_id and vote='gone'
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

-- 匿名化的回報不算「投票自動建立」；其餘與 202610260020_review_resolution_kind.sql 相同。
create or replace function public.admin_review_baseline(p_months int default 12)
returns table(month date,reports int,reporters int,auto_reports int,resolved int,admin_resolved int,
  median_hours numeric,by_status jsonb,by_resolution_kind jsonb,by_risk jsonb)
language plpgsql stable security invoker set search_path='' as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_months is null or p_months not between 1 and 60 then
    raise exception 'p_months must be between 1 and 60' using errcode='22023';
  end if;
  return query
  with months as (
    select (date_trunc('month',now() at time zone 'Asia/Taipei')-make_interval(months=>g))::date as m
    from generate_series(0,p_months-1) g
  ), q as (
    select q.*,(date_trunc('month',q.created_at at time zone 'Asia/Taipei'))::date as created_m,
      (date_trunc('month',q.resolved_at at time zone 'Asia/Taipei'))::date as resolved_m
    from public.moderation_queue q
    where q.created_at>=(select min(m) from months)::timestamp at time zone 'Asia/Taipei'
       or q.resolved_at>=(select min(m) from months)::timestamp at time zone 'Asia/Taipei'
  )
  select mo.m,
    (select count(*)::int from q where q.created_m=mo.m),
    (select count(distinct q.reporter_id)::int from q where q.created_m=mo.m),
    (select count(*)::int from q where q.created_m=mo.m and q.reporter_id is null and q.anonymized_at is null),
    (select count(*)::int from q where q.resolved_m=mo.m),
    (select count(*)::int from q where q.resolved_m=mo.m and q.resolved_by is not null),
    (select round((percentile_cont(0.5) within group (order by extract(epoch from q.resolved_at-q.created_at)/3600))::numeric,1)
      from q where q.resolved_m=mo.m and q.resolved_by is not null),
    (select coalesce(jsonb_object_agg(s,n),'{}') from(select q.status s,count(*) n from q where q.resolved_m=mo.m group by 1) x),
    (select coalesce(jsonb_object_agg(s,n),'{}') from(select coalesce(q.resolution_kind,'unclassified') s,count(*) n
      from q where q.resolved_m=mo.m group by 1) x),
    (select coalesce(jsonb_object_agg(s,n),'{}') from(select coalesce(q.risk,'unclassified') s,count(*) n
      from q where q.created_m=mo.m group by 1) x)
  from months mo
  order by mo.m desc;
end;
$$;
revoke execute on function public.admin_review_baseline(int) from public,anon;
grant execute on function public.admin_review_baseline(int) to authenticated;

-- ===== 2. 申請、取消、查詢 =====
create table private.account_deletion_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- 稽核用的隨機編號；稽核不存 user_id。
  request_id uuid not null unique default gen_random_uuid(),
  source text not null check (source in ('app','web')),
  requested_at timestamptz not null default now(),
  scheduled_at timestamptz not null,
  -- 執行器領取的時間；領取後 1 小時內不能取消，避免刪到一半被取消。
  claimed_at timestamptz,
  attempts integer not null default 0 check (attempts>=0),
  last_error text check (char_length(last_error)<=200),
  check (scheduled_at>requested_at)
);
create index account_deletion_due_idx on private.account_deletion_requests(scheduled_at);
alter table private.account_deletion_requests enable row level security;
revoke all on private.account_deletion_requests from public,anon,authenticated,service_role;

-- 最近一次取消（App 依此在登入後顯示「已取消刪除」）。再申請時清除，
-- 帳號刪除時跟著刪除。
create table private.account_deletion_cancellations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  cancelled_at timestamptz not null default now(),
  by_sign_in boolean not null
);
alter table private.account_deletion_cancellations enable row level security;
revoke all on private.account_deletion_cancellations from public,anon,authenticated,service_role;

create table private.account_deletion_audit (
  id bigint generated always as identity primary key,
  request_id uuid not null,
  event text not null check (event in ('requested','cancelled','executed','failed')),
  source text not null check (source in ('app','web')),
  -- executed：匿名化與刪除的筆數；failed：錯誤代碼。沒有個人資料。
  counts jsonb,
  error text check (char_length(error)<=200),
  at timestamptz not null default now()
);
create index account_deletion_audit_request_idx on private.account_deletion_audit(request_id,at);
alter table private.account_deletion_audit enable row level security;
revoke all on private.account_deletion_audit from public,anon,authenticated,service_role;
create trigger account_deletion_audit_immutable before update or delete on private.account_deletion_audit
  for each row execute function public.admin_audit_log_immutable();
create trigger account_deletion_audit_no_truncate before truncate on private.account_deletion_audit
  for each statement execute function public.admin_audit_log_immutable();

-- 冷靜期長度與「近期登入」的時間窗。
create function private.account_deletion_cooling_off() returns interval
language sql immutable set search_path='' as $$ select interval '7 days' $$;
revoke execute on function private.account_deletion_cooling_off() from public,anon,authenticated,service_role;
create function private.account_deletion_reauth_window() returns interval
language sql immutable set search_path='' as $$ select interval '10 minutes' $$;
revoke execute on function private.account_deletion_reauth_window() from public,anon,authenticated,service_role;

-- 呼叫者：已登入、不是匿名登入、帳號還在；否則 PT401 auth.sign_in_required。
create function private.account_deletion_caller() returns uuid
language plpgsql stable security definer set search_path='' as $$
declare
  v_user uuid:=auth.uid();
begin
  if v_user is null or coalesce(auth.jwt()->>'is_anonymous','false')='true'
     or not exists(select 1 from auth.users u
       where u.id=v_user and not u.is_anonymous and u.deleted_at is null) then
    raise sqlstate 'PT401' using message='auth.sign_in_required';
  end if;
  return v_user;
end $$;
revoke execute on function private.account_deletion_caller() from public,anon,authenticated,service_role;

-- 最近一次驗證（JWT amr，最新在前；refresh token 換發不會更新）在時間窗內。
-- 匿名登入不算。
create function private.signed_in_within(p_window interval) returns boolean
language sql stable set search_path='' as $$
  select coalesce((
    select max((e->>'timestamp')::numeric)
    from jsonb_array_elements(case when jsonb_typeof(auth.jwt()->'amr')='array'
      then auth.jwt()->'amr' else '[]'::jsonb end) e
    where jsonb_typeof(e)='object' and jsonb_typeof(e->'timestamp')='number'
      and coalesce(e->>'method','')<>'anonymous'
  ),0)>=extract(epoch from now()-p_window);
$$;
revoke execute on function private.signed_in_within(interval) from public,anon,authenticated,service_role;

-- 管理員（app metadata，使用者自己改不了）。
create function private.account_is_admin(p_user uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users u where u.id=p_user and u.raw_app_meta_data->>'role'='admin');
$$;
revoke execute on function private.account_is_admin(uuid) from public,anon,authenticated,service_role;

create function private.account_deletion_state(p_user uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select coalesce(
    (select jsonb_build_object('status','pending','requested_at',r.requested_at,'scheduled_at',r.scheduled_at)
      from private.account_deletion_requests r where r.user_id=p_user),
    jsonb_build_object('status','none','requested_at',null,'scheduled_at',null))
  ||jsonb_build_object(
    'cancelled_at',(select c.cancelled_at from private.account_deletion_cancellations c where c.user_id=p_user),
    'cancelled_by_sign_in',(select c.by_sign_in from private.account_deletion_cancellations c where c.user_id=p_user),
    -- App 在說明頁就能提示「要先移除管理權限」（Q-APP-22）。
    'can_self_delete',not private.account_is_admin(p_user),
    'cannot_self_delete_reason',case when private.account_is_admin(p_user) then 'account.admin_cannot_self_delete' end);
$$;
revoke execute on function private.account_deletion_state(uuid) from public,anon,authenticated,service_role;

-- 取消一筆申請：刪除、稽核、恢復點位上的名稱。
create function private.account_deletion_cancel(p private.account_deletion_requests,p_by_sign_in boolean) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
  delete from private.account_deletion_requests r where r.user_id=p.user_id;
  insert into private.account_deletion_cancellations(user_id,by_sign_in) values(p.user_id,p_by_sign_in)
    on conflict(user_id) do update set cancelled_at=now(),by_sign_in=excluded.by_sign_in;
  insert into private.account_deletion_audit(request_id,event,source) values(p.request_id,'cancelled',p.source);
  update public.community_spots s set contributor_name='' where s.user_id=p.user_id;
end $$;
revoke execute on function private.account_deletion_cancel(private.account_deletion_requests,boolean) from public,anon,authenticated,service_role;

create function api_v1.account_deletion_status() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  return private.account_deletion_state(private.account_deletion_caller());
end $$;
revoke execute on function api_v1.account_deletion_status() from public;
grant execute on function api_v1.account_deletion_status() to authenticated,service_role;

-- 申請刪除：已有申請就回原申請（不重設日期）；新申請要 10 分鐘內登入過。
create function api_v1.request_account_deletion(p_source text default 'app') returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_user uuid:=private.account_deletion_caller();
  v_request uuid;
begin
  if p_source is null or p_source not in ('app','web') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_source"}';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:'||v_user::text,0));
  if exists(select 1 from private.account_deletion_requests r where r.user_id=v_user) then
    return private.account_deletion_state(v_user);
  end if;
  if private.account_is_admin(v_user) then
    raise sqlstate 'PT403' using message='account.admin_cannot_self_delete';
  end if;
  if not private.signed_in_within(private.account_deletion_reauth_window()) then
    raise sqlstate 'PT401' using message='auth.recent_sign_in_required',
      detail=jsonb_build_object('max_age_seconds',
        extract(epoch from private.account_deletion_reauth_window())::int)::text;
  end if;
  insert into private.account_deletion_requests(user_id,source,scheduled_at)
    values(v_user,p_source,now()+private.account_deletion_cooling_off())
    returning request_id into v_request;
  delete from private.account_deletion_cancellations c where c.user_id=v_user;
  insert into private.account_deletion_audit(request_id,event,source) values(v_request,'requested',p_source);
  -- 名稱立刻從點位上拿掉（觸發器依申請重算）。
  update public.community_spots s set contributor_name='' where s.user_id=v_user;
  return private.account_deletion_state(v_user);
end $$;
revoke execute on function api_v1.request_account_deletion(text) from public;
grant execute on function api_v1.request_account_deletion(text) to authenticated,service_role;

-- 取消：冷靜期內任何時候；沒有申請也成功。執行器已領取（正在刪）時 PT409。
create function api_v1.cancel_account_deletion() returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_user uuid:=private.account_deletion_caller();
  v private.account_deletion_requests;
begin
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:'||v_user::text,0));
  select * into v from private.account_deletion_requests r where r.user_id=v_user for update;
  if found then
    if v.claimed_at>now()-interval '1 hour' then
      raise sqlstate 'PT409' using message='account.deletion_in_progress';
    end if;
    perform private.account_deletion_cancel(v,false);
  end if;
  return private.account_deletion_state(v_user);
end $$;
revoke execute on function api_v1.cancel_account_deletion() from public;
grant execute on function api_v1.cancel_account_deletion() to authenticated,service_role;

-- ===== 3. 到期執行（只給 Edge Function account-deletion 的 service role）=====
-- 領取到期的申請，一次最多 p_limit 筆；1 小時內領過的（另一次執行還在
-- 處理，或這次執行已失敗過）跳過。重試次數少的先領，持續失敗的申請不會
-- 佔滿每次的批次、讓其他到期申請永遠輪不到（Codex review，PR #270）。
create function public.account_deletion_claim(p_limit int default 20)
returns table(request_id uuid,user_id uuid,source text)
language sql volatile security definer set search_path='' as $$
  update private.account_deletion_requests r
    set claimed_at=now(),attempts=r.attempts+1
  from (select d.user_id from private.account_deletion_requests d
      where d.scheduled_at<=now() and (d.claimed_at is null or d.claimed_at<=now()-interval '1 hour')
      order by d.attempts,d.scheduled_at limit greatest(1,least(coalesce(p_limit,20),100))
      for update skip locked) due
  where r.user_id=due.user_id
  returning r.request_id,r.user_id,r.source;
$$;
revoke execute on function public.account_deletion_claim(int) from public,anon,authenticated;
grant execute on function public.account_deletion_claim(int) to service_role;

-- 刪除前的筆數（給稽核）；申請已不存在或不是這次領取的就回 null。
create function public.account_deletion_prepare(p_request uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  v_user uuid;
begin
  select r.user_id into v_user from private.account_deletion_requests r
    where r.request_id=p_request and r.claimed_at>now()-interval '1 hour';
  if v_user is null then return null; end if;
  -- 冷靜期內才被設為管理員：不刪，留給管理員處理（每次執行記為失敗）。
  if private.account_is_admin(v_user) then
    raise exception 'account.admin_cannot_self_delete' using errcode='42501';
  end if;
  return jsonb_build_object(
    'spots',(select count(*) from public.community_spots s where s.user_id=v_user),
    'votes',(select count(*) from public.spot_votes v where v.user_id=v_user),
    'reports',(select count(*) from public.moderation_queue q where q.reporter_id=v_user),
    'reports_pending',(select count(*) from public.moderation_queue q where q.reporter_id=v_user and q.resolved_at is null),
    'sightings',(select count(*) from public.rider_sightings s where s.user_id=v_user),
    'favorites',(select count(*) from public.favorites f where f.user_id=v_user));
end $$;
revoke execute on function public.account_deletion_prepare(uuid) from public,anon,authenticated;
grant execute on function public.account_deletion_prepare(uuid) to service_role;

-- 帳號刪除後寫稽核；帳號還在（申請列還在）就拒絕。
create function public.account_deletion_finish(p_request uuid,p_source text,p_counts jsonb) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
  if exists(select 1 from private.account_deletion_requests r where r.request_id=p_request) then
    raise exception 'account still exists' using errcode='55000';
  end if;
  insert into private.account_deletion_audit(request_id,event,source,counts)
    values(p_request,'executed',p_source,
      case when jsonb_typeof(p_counts)='object' then p_counts end);
end $$;
revoke execute on function public.account_deletion_finish(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.account_deletion_finish(uuid,text,jsonb) to service_role;

-- 失敗：記錄錯誤代碼（不含個人資料）。領取時間保留，1 小時後才能再領，
-- 所以同一次執行不會重試它；下一次每日執行再試。
create function public.account_deletion_fail(p_request uuid,p_error text) returns void
language plpgsql volatile security definer set search_path='' as $$
declare
  v_source text;
  v_error text:=left(coalesce(p_error,'unknown'),200);
begin
  update private.account_deletion_requests r set last_error=v_error
    where r.request_id=p_request returning r.source into v_source;
  if found then
    insert into private.account_deletion_audit(request_id,event,source,error)
      values(p_request,'failed',v_source,v_error);
  end if;
end $$;
revoke execute on function public.account_deletion_fail(uuid,text) from public,anon,authenticated;
grant execute on function public.account_deletion_fail(uuid,text) to service_role;

-- pg_cron 每日（台灣 03:41）叫 Edge Function；vault 沒有 project_url 或
-- account_deletion_secret 時不做事。沒有到期的申請也不叫。
create function public.account_deletion_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text;
begin
  if not exists(select 1 from private.account_deletion_requests r where r.scheduled_at<=now()) then
    return null;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='account_deletion_secret';
  if v_url is null or v_secret is null or v_url !~ '^https://' then return null; end if;
  return net.http_post(
    url:=rtrim(v_url,'/')||'/functions/v1/account-deletion',
    headers:=jsonb_build_object('Content-Type','application/json','x-deletion-secret',v_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=120000);
end $$;
revoke all on function public.account_deletion_tick() from public,anon,authenticated;

select cron.schedule('account-deletion','41 19 * * *','select public.account_deletion_tick()');

-- ===== 5. 冷靜期內的名稱與登入 =====
-- 有刪除申請的帳號不公開名稱；其餘與 202610250050_contributor_attribution.sql 相同。
create or replace function public.spot_contributor_name(p_spot uuid,p_user uuid,p_role text)
returns text language sql stable security invoker set search_path='' as $$
  select case when p_role<>'rider'
      or exists(select 1 from public.contributor_name_clears c where c.spot_id=p_spot)
      or exists(select 1 from private.account_deletion_requests r where r.user_id=p_user) then ''
    else coalesce((select public.contributor_display_name(u.raw_user_meta_data)
      from auth.users u where u.id=p_user and u.deleted_at is null),'') end;
$$;
revoke execute on function public.spot_contributor_name(uuid,uuid,text) from public,anon,authenticated,service_role;

-- 冷靜期內的新登入就取消申請。新登入＝auth.sessions 新增一列（refresh
-- 只換 token，不會新增 session；last_sign_in_at 在舊版 refresh 也會更新，
-- 所以不用它）。申請前那次重新登入的 session 比申請早，不會觸發。
-- 這裡出錯不能讓登入失敗：例外只記警告。
create function public.account_deletion_cancel_on_sign_in() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v private.account_deletion_requests;
begin
  select * into v from private.account_deletion_requests r
    where r.user_id=new.user_id and r.requested_at<coalesce(new.created_at,now())
      and (r.claimed_at is null or r.claimed_at<=now()-interval '1 hour')
    for update;
  if found then
    perform private.account_deletion_cancel(v,true);
  end if;
  return null;
exception when others then
  raise warning 'account deletion cancel on sign-in failed: %',sqlstate;
  return null;
end $$;
revoke execute on function public.account_deletion_cancel_on_sign_in() from public,anon,authenticated,service_role;
create trigger account_deletion_cancel_on_sign_in after insert on auth.sessions
  for each row execute function public.account_deletion_cancel_on_sign_in();
