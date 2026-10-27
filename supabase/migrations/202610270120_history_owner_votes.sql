-- Edit history: riders' own changes and votes, and closures (decision 56;
-- #155 items 22 and 30). 202610270100_spot_history.sql read only what the
-- audit log and decided reports record; a spot's owner editing it through
-- a report (apply_report 'update') and riders' votes left no trace. Now:
--   spot_rider_events  one row per owner edit (its fields before and after)
--     and per vote (the vote, and the status it moved the spot from and to).
--     Written by triggers; apply_report (202610270050_precheck_hold.sql's,
--     unchanged otherwise) marks its owner edit with app.owner_update so the
--     trigger knows it. Read only through the history functions (no grants,
--     RLS on, no policies).
--   spot_history_entries  lists them: kind 'owner' (車友更新) and 'vote'.
--   admin_spot_history  every vote is its own entry, with who; the 200
--     limit applies to votes only, so they never push edits off the list.
--   spot_history  merges each run of consecutive votes into one entry
--     ({kind:'vote', votes:{still_there,gone}}, 「3 位車友確認仍在」),
--     counting each rider once by their last vote in the run, never naming
--     them; entries riders cannot see do not split a run; the status a run left the spot in
--     is given while the spot still holds it.
--   closure (#116) joins the fields history compares, public ones included.

create table public.spot_rider_events (
  id bigint generated always as identity primary key,
  spot_id uuid not null references public.community_spots(id) on delete cascade,
  -- clock_timestamp: several in one transaction keep their order.
  at timestamptz not null default clock_timestamp(),
  kind text not null check (kind in ('owner_update','vote')),
  -- The owner, or the rider who voted; gone with their account.
  actor uuid references auth.users(id) on delete set null,
  vote text check ((kind='vote')=(vote is not null) and (vote is null or vote in ('still_there','gone'))),
  -- History fields only (spot_history_fields()): the fields an owner edit
  -- changed, before and after; a vote's {status} when it moved the spot,
  -- else null.
  before jsonb,
  after jsonb
);
create index spot_rider_events_spot_idx on public.spot_rider_events(spot_id,at desc);
alter table public.spot_rider_events enable row level security;
revoke all on public.spot_rider_events from public,anon,authenticated;
comment on table public.spot_rider_events is
  'Owner edits and votes for the edit history (#141, decision 56); written by triggers, read by spot_history_entries().';

-- The fields a history entry compares, in display order: 0100's list and
-- the temporary closure.
create or replace function public.spot_history_fields() returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','parking_access','parking_zones','zones_complete','scooter_allowed','heavy_allowed',
    'scooter_verified_at','heavy_verified_at','fee','fee_note','fee_plan','fee_plans','fee_source_text',
    'scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note','closure','status','hidden',
    'source_name','source_url','effective_date','license_note','contributor_name'];
$$;

-- Riders already read a spot's closure (granted to anon), so its changes
-- are public too.
create or replace function public.spot_history_public_fields() returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','parking_access','parking_zones','zones_complete','scooter_allowed','heavy_allowed',
    'fee','fee_note','scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note','closure',
    'source_name','source_url','effective_date','license_note'];
$$;

-- [p_row] cut down to the fields history compares.
create function public.spot_history_slice(p_row jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) from jsonb_each(p_row) e(k,v)
  where k=any(public.spot_history_fields());
$$;
revoke execute on function public.spot_history_slice(jsonb) from public,anon,authenticated;

-- Each vote apply_report records (a new vote, or a rider changing theirs).
-- apply_report then always updates the spot; app.vote_event (transaction
-- local) hands this event to that update, which clears it.
create function public.spot_votes_history() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_id bigint;
begin
  insert into public.spot_rider_events(spot_id,kind,actor,vote) values(new.spot_id,'vote',new.user_id,new.vote)
    returning id into v_id;
  perform set_config('app.vote_event',v_id::text,true);
  return null;
end;
$$;
revoke execute on function public.spot_votes_history() from public,anon,authenticated;
create trigger spot_votes_history after insert or update of vote,created_at on public.spot_votes
  for each row execute function public.spot_votes_history();

-- 202610270050_precheck_hold.sql's apply_report, unchanged except that the
-- owner's edit sets app.owner_update for the trigger below.
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
$$;

-- A community spot's update by apply_report:
--   right after a vote on it, the status it moved the spot to is that
--   vote's (apply_report 'vote', app.vote_event);
--   apply_report 'update' marks the owner's own edit (app.owner_update).
-- Each mark names the spot and is cleared once used. Every other write
-- (administrators' RPCs, which the audit log covers; migrations,
-- maintenance, a service-role UPDATE) is not a rider's change.
create function public.community_spots_rider_history() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_vote bigint;
  v_before jsonb; v_after jsonb;
begin
  if coalesce(public.is_admin(),false) then return null; end if;
  select e.id into v_vote from public.spot_rider_events e
    where e.id=nullif(current_setting('app.vote_event',true),'')::bigint and e.spot_id=new.id and e.kind='vote';
  if v_vote is not null then
    perform set_config('app.vote_event','',true);
    if old.status is distinct from new.status then
      update public.spot_rider_events
        set before=coalesce(before,jsonb_build_object('status',old.status)),after=jsonb_build_object('status',new.status)
        where id=v_vote;
    end if;
  elsif current_setting('app.owner_update',true)=new.id::text then
    perform set_config('app.owner_update','',true);
    -- Only the fields the edit changed.
    select jsonb_object_agg(b.k,b.v),jsonb_object_agg(b.k,a.v) into v_before,v_after
      from jsonb_each(public.spot_history_slice(to_jsonb(old))) b(k,v)
      join jsonb_each(public.spot_history_slice(to_jsonb(new))) a(k,v) on a.k=b.k
      where a.v is distinct from b.v;
    if v_after is not null then
      insert into public.spot_rider_events(spot_id,kind,actor,before,after)
      values(new.id,'owner_update',new.user_id,v_before,v_after);
    end if;
  end if;
  return null;
end;
$$;
revoke execute on function public.community_spots_rider_history() from public,anon,authenticated;
create trigger community_spots_rider_history after update on public.community_spots
  for each row execute function public.community_spots_rider_history();

-- 202610270100_spot_history.sql's timeline plus riders' own edits and votes:
--   owner  the spot's owner changed it through a report (車友更新)
--   vote   a rider voted; action vote_still_there or vote_gone, changes the
--          status it moved the spot to, if any
create or replace function public.spot_history_entries(p_source_id text)
returns table(at timestamptz,kind text,action text,actor uuid,created boolean,changes jsonb,
  note text,source_name text,report jsonb)
language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare
  v_official boolean:=p_source_id like 'official:%';
  v_raw text:=case when p_source_id like 'official:%' then substr(p_source_id,10) else p_source_id end;
  v_table text:=case when p_source_id like 'official:%' then 'official_heavy_spots' else 'community_spots' end;
  v_id uuid;
begin
  if v_raw is null or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return; end if;
  v_id:=v_raw::uuid;
  return query
  with audited as (
    -- Writes to the spot row itself.
    select a.created_at,a.action,a.actor,a.before,a.after,a.note from admin_audit_log a
    where a.target_table=v_table and a.target_id=v_id::text
      and a.action in ('create_spot','update_spot','import_spot','convert_fee','hide_spot','restore_spot',
        'clear_contributor_name','promote_spot')
    union all
    -- The official spot a community spot was promoted into starts there.
    select a.created_at,'promoted_from',a.actor,null,a.after->'official',a.note from admin_audit_log a
    where v_official and a.action='promote_spot' and a.after->'official'->>'id'=v_id::text
  ),
  decided as (
    -- Reports an administrator accepted or rejected, with what the
    -- acceptance changed. Reports resolved in the Dashboard before the
    -- admin site ('closed') carry no decision and are left out.
    select coalesce(q.resolved_at,r.created_at) as at,q.status,r.actor,r.before->'spot' as before,
      r.after->'spot' as after,q.resolution_note,
      jsonb_build_object('id',q.id,'status',q.status,'reason',q.reason,'field',q.field,'proposed',q.proposed,
        'note',q.note,'evidence_url',q.evidence_url,'resolution_note',q.resolution_note,
        'resolution_kind',q.resolution_kind,'created_at',q.created_at,'resolved_at',q.resolved_at) as report
    from moderation_queue q
    left join lateral (select a.created_at,a.actor,a.before,a.after from admin_audit_log a
      where a.action='resolve_report' and a.target_table='moderation_queue' and a.target_id=q.id::text
      order by a.created_at desc limit 1) r on true
    where q.source_id=p_source_id and q.status in ('accepted','rejected')
  )
  select x.created_at,
    case when x.action in ('import_spot','convert_fee') then 'import' else 'admin' end,
    x.action,x.actor,
    x.action in ('create_spot','promoted_from') or (x.action='import_spot' and x.before is null),
    case when x.action in ('create_spot','promoted_from') or (x.action='import_spot' and x.before is null)
      then '[]'::jsonb else public.spot_history_changes(x.before,x.after) end,
    x.note,
    case when x.action='import_spot' then nullif(x.after->>'source_name','') end,
    null::jsonb
  from audited x
  union all
  select d.at,'report','resolve_report',d.actor,false,
    case when d.status='accepted' then public.spot_history_changes(d.before,d.after) else '[]'::jsonb end,
    d.resolution_note,null,d.report
  from decided d
  union all
  -- A spot a rider added through the app has no audit entry for its creation.
  select c.created_at,case when c.contributor_role='import' then 'import' else 'report' end,'create',
    null::uuid,true,'[]'::jsonb,'',null,null
  from community_spots c
  where not v_official and c.id=v_id and not exists(select 1 from admin_audit_log a
    where a.target_table='community_spots' and a.target_id=v_id::text and a.action in ('create_spot','import_spot')
      and a.before is null)
  union all
  -- Riders' own edits and votes (decision 56).
  select e.at,case when e.kind='vote' then 'vote' else 'owner' end,
    case when e.kind='vote' then 'vote_'||e.vote else 'owner_update' end,
    e.actor,false,
    case when e.after is null then '[]'::jsonb else public.spot_history_changes(e.before,e.after) end,
    '',null,null
  from spot_rider_events e
  where not v_official and e.spot_id=v_id
  order by 1 desc;
end;
$$;

-- The app's history (AppHistory): 0100's latest 10 changes, now with
-- riders' own edits, and each run of votes with nothing else between them
-- as one entry: how many riders said still there and gone (never who), and
-- the status the run left the spot in when it moved it and the spot still
-- holds it.
create or replace function public.spot_history(p_source_id text) returns jsonb
language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare
  v_raw text:=case when p_source_id like 'official:%' then substr(p_source_id,10) else p_source_id end;
  v_current jsonb;
begin
  if p_source_id is null or char_length(p_source_id)>100
     or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return '[]'::jsonb;
  end if;
  -- Hidden spots have no public page, so no public history either.
  if p_source_id like 'official:%' then
    select to_jsonb(o) into v_current from official_heavy_spots o where o.id=v_raw::uuid and not o.hidden;
  else
    select to_jsonb(c) into v_current from community_spots c where c.id=v_raw::uuid and c.status<>'hidden';
  end if;
  if v_current is null then return '[]'::jsonb; end if;
  return (
    with x as (
      select x.*,
        -- What riders may see of a non-vote entry: public fields, a value
        -- only while the spot still holds it.
        case when x.kind='vote' then x.changes else
          (select coalesce(jsonb_agg(case when v_current->(c->>'field') is not distinct from c->'after'
              then jsonb_build_object('field',c->>'field','after',c->'after')
              else jsonb_build_object('field',c->>'field') end order by n),'[]'::jsonb)
            from jsonb_array_elements(x.changes) with ordinality j(c,n)
            where c->>'field'=any(public.spot_history_public_fields())) end as shown
      from public.spot_history_entries(p_source_id) x
      where x.report is null or x.report->>'status'='accepted'
    ),
    -- Entries riders cannot see are dropped first, so they never split a
    -- run of votes into two.
    e as (
      select x.*,
        -- Consecutive votes share an island number.
        row_number() over (order by x.at desc)
          - row_number() over (partition by x.kind='vote' order by x.at desc) as island
      from x where x.kind='vote' or x.created or jsonb_array_length(x.shown)>0
    ),
    singles as (
      select e.at,e.kind,e.created,e.shown as changes from e where e.kind<>'vote'
    ),
    -- Each rider counts once per run, by their last vote in it.
    last_votes as (
      select distinct on (e.island,coalesce(e.actor::text,e.at::text)) e.island,e.action
      from e where e.kind='vote'
      order by e.island,coalesce(e.actor::text,e.at::text),e.at desc
    ),
    runs as (
      select e.island,max(e.at) as at,
        (select count(*) from last_votes l where l.island=e.island and l.action='vote_still_there') as still_there,
        (select count(*) from last_votes l where l.island=e.island and l.action='vote_gone') as gone,
        (jsonb_agg(e.changes->0->'before' order by e.at) filter (where jsonb_array_length(e.changes)>0))->0 as first_before,
        (jsonb_agg(e.changes->0->'after' order by e.at desc) filter (where jsonb_array_length(e.changes)>0))->0 as last_after
      from e where e.kind='vote' group by e.island
    ),
    listed as (
      select s.at,jsonb_build_object('at',s.at,'kind',s.kind,'created',s.created,'changes',s.changes) as j
      from singles s
      union all
      select r.at,jsonb_build_object('at',r.at,'kind','vote','created',false,
        'votes',jsonb_build_object('still_there',r.still_there,'gone',r.gone),
        'changes',case
          when r.last_after is null or r.first_before is not distinct from r.last_after then '[]'::jsonb
          when v_current->'status' is not distinct from r.last_after
            then jsonb_build_array(jsonb_build_object('field','status','after',r.last_after))
          else jsonb_build_array(jsonb_build_object('field','status')) end) as j
      from runs r
    )
    select coalesce(jsonb_agg(l.j order by l.at desc),'[]'::jsonb)
    from (select * from listed order by at desc limit 10) l);
end;
$$;

-- 202610270100_spot_history.sql's admin timeline: every entry but votes, and
-- the latest 200 votes, so a busy spot's votes never push its edits off.
create or replace function public.admin_spot_history(p_source_id text) returns jsonb
language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_source_id is null or char_length(p_source_id)>100 then
    raise exception 'invalid spot' using errcode='22023';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'at',e.at,'kind',e.kind,'action',e.action,
      'actor_name',case when e.actor is null then null
        else coalesce((select nullif(public.contributor_display_name(u.raw_user_meta_data),'')
          from auth.users u where u.id=e.actor),'') end,
      'created',e.created,'changes',e.changes,'note',e.note,'source_name',e.source_name,'report',e.report)
    order by e.at desc),'[]'::jsonb)
    from (select * from public.spot_history_entries(p_source_id) where kind<>'vote'
      union all
      (select * from public.spot_history_entries(p_source_id) where kind='vote' order by at desc limit 200)) e);
end;
$$;
