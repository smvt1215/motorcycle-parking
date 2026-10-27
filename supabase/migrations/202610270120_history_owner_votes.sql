-- Edit history: riders' own changes and votes, and closures (decision 56;
-- #155 items 22 and 30). 202610270100_spot_history.sql read only what the
-- audit log and decided reports record; a spot's owner editing it through
-- a report (apply_report 'update') and riders' votes left no trace. Now:
--   spot_rider_events  one row per owner edit (its fields before and after)
--     and per vote (the vote, and the status it moved the spot from and to).
--     Written by triggers, so apply_report itself is unchanged; read only
--     through the history functions (no grants, RLS on, no policies).
--   spot_history_entries  lists them: kind 'owner' (車友更新) and 'vote'.
--   admin_spot_history  unchanged: every vote is its own entry, with who.
--   spot_history  merges each run of consecutive votes into one entry
--     ({kind:'vote', votes:{still_there,gone}}, 「3 位車友確認仍在」),
--     counting riders, never naming them; the status a run left the spot in
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
  -- History fields only (spot_history_fields()): an owner edit's whole
  -- before and after; a vote's {status} when it moved the spot, else null.
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

-- A community spot's update outside the administrators' audited RPCs:
--   right after a vote on it, the status it moved the spot to is that
--   vote's (apply_report 'vote');
--   otherwise, made by the submit-report function (service role), it is the
--   owner's own edit (apply_report 'update'). Administrators' writes are in
--   the audit log already; migrations and maintenance run without a JWT and
--   are not riders' changes.
create function public.community_spots_rider_history() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_role text:=coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',
    nullif(current_setting('request.jwt.claim.role',true),''));
  v_vote bigint;
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
  elsif v_role='service_role' then
    if public.spot_history_slice(to_jsonb(old)) is distinct from public.spot_history_slice(to_jsonb(new)) then
      insert into public.spot_rider_events(spot_id,kind,actor,before,after)
      values(new.id,'owner_update',new.user_id,public.spot_history_slice(to_jsonb(old)),public.spot_history_slice(to_jsonb(new)));
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
    with e as (
      select x.*,
        -- Consecutive votes share an island number.
        row_number() over (order by x.at desc)
          - row_number() over (partition by x.kind='vote' order by x.at desc) as island
      from public.spot_history_entries(p_source_id) x
      where x.report is null or x.report->>'status'='accepted'
    ),
    singles as (
      select e.at,e.kind,e.created,
        (select coalesce(jsonb_agg(case when v_current->(c->>'field') is not distinct from c->'after'
            then jsonb_build_object('field',c->>'field','after',c->'after')
            else jsonb_build_object('field',c->>'field') end order by n),'[]'::jsonb)
          from jsonb_array_elements(e.changes) with ordinality j(c,n)
          where c->>'field'=any(public.spot_history_public_fields())) as changes
      from e where e.kind<>'vote'
    ),
    runs as (
      select max(e.at) as at,
        count(distinct coalesce(e.actor::text,e.at::text)) filter (where e.action='vote_still_there') as still_there,
        count(distinct coalesce(e.actor::text,e.at::text)) filter (where e.action='vote_gone') as gone,
        (jsonb_agg(e.changes->0->'before' order by e.at) filter (where jsonb_array_length(e.changes)>0))->0 as first_before,
        (jsonb_agg(e.changes->0->'after' order by e.at desc) filter (where jsonb_array_length(e.changes)>0))->0 as last_after
      from e where e.kind='vote' group by e.island
    ),
    listed as (
      select s.at,jsonb_build_object('at',s.at,'kind',s.kind,'created',s.created,'changes',s.changes) as j
      from singles s where s.created or jsonb_array_length(s.changes)>0
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
