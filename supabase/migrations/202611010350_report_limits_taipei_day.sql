-- 回報（apply_report）的每日上限改依 App Check 階段（#203，使用者 2026-10-31），
-- 比照騎士回報（202610310110_sightings_daily_limits.sql）：
--
-- 1. 一天從台灣時間 0 點起算，不再用 UTC（原本是台灣早上 8 點重算）。
-- 2. 每帳號每日 10 筆，不變。
-- 3. 每網路每日 200 筆（原本 30 筆），只在 App Check 只記錄期間硬擋；
--    submit-report 在 APP_CHECK_MODE=enforce 時傳 p_ip_capped=false，
--    此後超過 200 筆是風險訊號：照收，rate_limit_events.ip_busy 標記，
--    新增點位與檢舉帶 ip_busy 風險旗標送審（新增點位多需 1 票確認），
--    確認票以未合格（0.25 權重、不計入確認）計。
-- 網路只存 submit-report 以 REPORT_HASH_SECRET 算的 HMAC-SHA256（ip_hash，
-- 64 字元，apply_report 拒收其他長度）；rate_limit_events 從未存原始 IP，
-- 舊資料不需轉換。
--
-- 只改限流段落；apply_report 其餘邏輯與 202610310300_soft_delete_spots.sql
-- 相同。管理站使用者頁的「今天」計數改用同一個日界線。

alter table public.rate_limit_events add column ip_busy boolean not null default false;
comment on column public.rate_limit_events.ip_busy is
  '送出時同一網路當日已逾 200 筆（App Check 強制後的風險訊號，#203）。';

-- When today's report quota began: midnight in Taiwan.
create function public.report_day_start() returns timestamptz
language sql stable set search_path='' as $$
  select date_trunc('day',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
$$;
revoke execute on function public.report_day_start() from public,anon,authenticated;

drop function public.apply_report(uuid,text,text,jsonb);

CREATE FUNCTION public.apply_report(p_user uuid, p_ip text, p_device text, p_payload jsonb, p_ip_capped boolean DEFAULT true)
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
    if v_owner is null then raise exception 'spot not found' using errcode='22023';end if;
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

create or replace function public.admin_user_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_day timestamptz:=public.report_day_start();
  v_since timestamptz:=now()-interval '30 days';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  perform 1 from auth.users u where u.id=p_user;
  if not found then raise exception 'user not found' using errcode='22023'; end if;
  return jsonb_build_object(
    'user',(select to_jsonb(a) from public.admin_users(p_user::text,1) a),
    -- apply_report allows 10 reports per account a day, the day starting at
    -- midnight in Taiwan (#203).
    'limits',jsonb_build_object(
      'today',(select count(*) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_day),
      'daily_limit',10,
      'last_7d',(select count(*) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=now()-interval '7 days'),
      'last_30d',(select count(*) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_since),
      'networks_30d',(select count(distinct r.ip_hash) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_since),
      'shared_accounts_30d',(select count(distinct o.user_id) from public.rate_limit_events o
        where o.created_at>=v_since and o.user_id<>p_user
          and o.ip_hash in (select r.ip_hash from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_since))),
    'events',coalesce((select jsonb_agg(jsonb_build_object('created_at',e.created_at,'network',left(e.ip_hash,6)) order by e.created_at desc)
      from (select r.created_at,r.ip_hash from public.rate_limit_events r where r.user_id=p_user order by r.created_at desc limit 30) e),'[]'),
    'reports',jsonb_build_object(
      'spots',(select count(*) from public.community_spots s where s.user_id=p_user and s.source='community'),
      'spots_hidden',(select count(*) from public.community_spots s where s.user_id=p_user and s.source='community' and s.status='hidden'),
      'votes_still_there',(select count(*) from public.spot_votes v where v.user_id=p_user and v.vote='still_there'),
      'votes_gone',(select count(*) from public.spot_votes v where v.user_id=p_user and v.vote='gone'),
      'flags_pending',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='pending'),
      'flags_accepted',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='accepted'),
      'flags_rejected',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='rejected'),
      'flags_closed',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='closed')),
    -- The newest points this account reported; admin_user_spots pages on.
    'spots',public.admin_user_spots(p_user,0,50),
    'history',coalesce((select jsonb_agg(jsonb_build_object('action',l.action,'note',l.note,'created_at',l.created_at,
        'banned_until',l.after->>'banned_until') order by l.created_at desc)
      from (select * from public.admin_audit_log a where a.target_table='auth.users' and a.target_id=p_user::text
        order by a.created_at desc limit 20) l),'[]')
  );
end;
$$;
revoke execute on function public.admin_user_detail(uuid) from public,anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;
