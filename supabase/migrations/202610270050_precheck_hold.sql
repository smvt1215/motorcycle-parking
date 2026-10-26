-- Precheck holds and rider evidence (docs/designs/2026-10-26-parking-conditions-and-fees.md
-- §4.2, §4.3; stack C, C5a). submit-report lets a request that breaks only
-- `hold` rules through and passes their codes as `risk_flags`; a rider may
-- attach a notice link (`evidence_url`, https). Both are kept on the case,
-- never on the spot. A new spot that is held, or carries a link, opens a
-- case; while a held case is open, confirming the spot takes one more vote
-- (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.8, decision 17). apply_report is
-- the 202610270010 definition with only these changes.

alter table public.moderation_queue
  add column if not exists risk_flags text[] not null default '{}',
  add column if not exists evidence_url text
    constraint moderation_queue_evidence_url_https
    check (evidence_url is null or (evidence_url ~ '^https://\S+$' and char_length(evidence_url)<=2048));

comment on column public.moderation_queue.risk_flags is
  'Precheck hold rules the report broke (precheck_rules.json codes); set by submit-report only.';
comment on column public.moderation_queue.evidence_url is
  'Notice link a rider attached as evidence (https); an admin decides whether it becomes a basis.';

create or replace function public.apply_report(p_user uuid,p_ip text,p_device text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_action text:=p_payload->>'action'; v_spot jsonb:=p_payload->'spot';
  v_id uuid; v_existing uuid; v_owner uuid; v_qualified boolean; v_score numeric; v_count integer; v_decided timestamptz;
  v_day timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
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
  if (select count(*) from rate_limit_events where user_id=p_user and created_at>=v_day)>=10 or
     (select count(*) from rate_limit_events where ip_hash=p_ip and created_at>=v_day)>=30 then
    raise exception 'daily report limit reached' using errcode='P0001';
  end if;
  insert into rate_limit_events(user_id,ip_hash) values(p_user,p_ip);
  if v_action='create' then
    -- One lock per space type prevents duplicate inserts racing from separate IPs.
    perform pg_advisory_xact_lock(hashtextextended('create:'||(v_spot->>'space_type'),0));
    select id into v_existing from community_spots where status<>'hidden' and space_type=v_spot->>'space_type'
      and extensions.st_dwithin(location,extensions.st_setsrid(extensions.st_makepoint((v_spot->>'lng')::float8,(v_spot->>'lat')::float8),4326)::extensions.geography,15) limit 1;
    if v_existing is not null then return jsonb_build_object('duplicate_id',v_existing);end if;
    -- A rider attaches a notice to a report as evidence; only admins and
    -- imports write a condition's basis (§1.4). validate.ts refuses it first.
    if v_spot->'condition' ? 'basis' or exists(select 1 from jsonb_array_elements(
        case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end) z
        where z->'condition' ? 'basis') then
      raise exception 'a report cannot set a condition basis' using errcode='22023';
    end if;
    insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,fee,
        facility_type,parking_access,entrance_note,parking_guide,parking_zones,condition)
    values(p_user,btrim(v_spot->>'name'),(v_spot->>'lat')::float8,(v_spot->>'lng')::float8,v_spot->>'city',coalesce(v_spot->>'district',''),v_spot->>'space_type',coalesce(v_spot->>'fee_note','請依現場公告'),coalesce(v_spot->>'note',''),(v_spot->>'scooter_allowed')::boolean,(v_spot->>'heavy_allowed')::boolean,
      case when jsonb_typeof(v_spot->'fee')='object' then v_spot->'fee' end,
      -- Lot details: how the lot is built, who parks where, how to get in and
      -- park, and its zones; submit-report/validate.ts checks their shape.
      nullif(v_spot->>'facility_type',''),nullif(v_spot->>'parking_access',''),
      btrim(coalesce(v_spot->>'entrance_note','')),btrim(coalesce(v_spot->>'parking_guide','')),
      case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end,
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
    select user_id into v_owner from community_spots where id=v_id and status<>'hidden' for update;
    if v_owner is null then raise exception 'spot not found' using errcode='22023';end if;
    if v_owner=p_user then raise exception 'cannot confirm own report' using errcode='42501';end if;
    if exists(select 1 from report_identities where spot_id=v_id and (ip_hash=p_ip or device_hash=p_device)) then v_qualified:=false;end if;
    insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
      values(v_id,p_user,p_payload->>'vote',v_qualified,case when v_qualified then 1 else 0.25 end,p_ip,p_device)
      on conflict(spot_id,user_id) do update set vote=excluded.vote,qualified=excluded.qualified,weight=excluded.weight,ip_hash=excluded.ip_hash,device_hash=excluded.device_hash,created_at=now();
    -- Distinct IP AND device, and two qualified users. Network/device sameness cannot inflate confirmations.
    select least(count(distinct ip_hash),count(distinct device_hash)) into v_count from spot_votes where spot_id=v_id and vote='still_there' and qualified;
    -- A spot created under a hold needs one more confirmation until an
    -- admin resolves its case (feasibility §5.8, decision 17).
    v_need:=2+case when exists(select 1 from moderation_queue where source_id=v_id::text
      and resolved_at is null and cardinality(risk_flags)>0) then 1 else 0 end;
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
    insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note,risk_flags,evidence_url)
    values(p_payload->>'source_id',p_user,p_payload->>'reason',nullif(btrim(coalesce(p_payload->>'field','')),''),
      case when jsonb_typeof(p_payload->'proposed')='object' then p_payload->'proposed' end,
      coalesce(p_payload->>'note',''),v_flags,v_evidence)
    on conflict do nothing;
  elsif v_action in ('update','delete') then
    v_id:=(p_payload->>'spot_id')::uuid;
    select user_id into v_owner from community_spots where id=v_id for update;
    if v_owner is distinct from p_user then raise exception 'only owner can edit' using errcode='42501';end if;
    if v_action='delete' then delete from community_spots where id=v_id;
    else
      update community_spots set name=btrim(v_spot->>'name'),fee_note=coalesce(v_spot->>'fee_note',fee_note),note=coalesce(v_spot->>'note',note),status='pending',last_confirmed_at=null,updated_at=now() where id=v_id;
      delete from spot_votes where spot_id=v_id;
    end if;
  else raise exception 'invalid report action' using errcode='22023';
  end if;
  return jsonb_build_object('id',v_id,'accepted',true);
end;
$$;
