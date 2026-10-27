-- Spot edit history (#141, C6 canvas EditHistory and AppHistory; decision 52).
-- One timeline per spot from what is already recorded: administrators'
-- audited writes (admin_audit_log), riders' reports an administrator
-- accepted or rejected (moderation_queue, with the resolve_report audit
-- entry for what the acceptance changed), imports and fee conversions, and
-- a rider-created spot's creation. No new table: the audit log stays the
-- record.
--   admin_spot_history(p_source_id)  administrators (aal2) only: every
--     entry with who, before and after, notes and the original report.
--   spot_history(p_source_id)  anyone: the latest 10 changes of a visible
--     spot, with no person, note or report, no rejected report and no
--     before value. A changed field's new value is given only while the
--     spot still holds it, so text an administrator later removed (for
--     example personal data in a note) never comes back through history.

-- Reports by spot, oldest index on the table that is read per spot.
create index if not exists moderation_queue_source_idx on public.moderation_queue(source_id,created_at desc);

-- The fields a history entry compares, in display order. Bookkeeping
-- columns (ids, updated_at, location, votes, live counts) are left out.
create function public.spot_history_fields() returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','parking_access','parking_zones','zones_complete','scooter_allowed','heavy_allowed',
    'scooter_verified_at','heavy_verified_at','fee','fee_note','fee_plan','fee_plans','fee_source_text',
    'scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note','status','hidden',
    'source_name','source_url','effective_date','license_note','contributor_name'];
$$;
revoke execute on function public.spot_history_fields() from public,anon,authenticated;

-- The fields riders may see in the app's history: public columns only, not
-- the administrator's checks, visibility, plan names, the import's source
-- text (decision 25) or the contributor's name.
create function public.spot_history_public_fields() returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','parking_access','parking_zones','zones_complete','scooter_allowed','heavy_allowed',
    'fee','fee_note','scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note',
    'source_name','source_url','effective_date','license_note'];
$$;
revoke execute on function public.spot_history_public_fields() from public,anon,authenticated;

-- What one write changed: each history field the new row carries whose
-- value differs from the old row. A write that carries only some fields
-- (convert_fee, clear_contributor_name) is compared on those alone.
create function public.spot_history_changes(p_before jsonb,p_after jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('field',f,'before',p_before->f,'after',p_after->f) order by n),'[]'::jsonb)
  from unnest(public.spot_history_fields()) with ordinality u(f,n)
  where jsonb_typeof(p_after)='object' and p_after ? f
    and (p_before is null or jsonb_typeof(p_before)<>'object' or (p_before->f) is distinct from (p_after->f));
$$;
revoke execute on function public.spot_history_changes(jsonb,jsonb) from public,anon,authenticated;

-- Every entry of [p_source_id]'s timeline, newest first. kind:
--   admin   an administrator's write in the spot form or review tools
--   import  an import or fee conversion
--   report  a rider's report an administrator decided, or a rider's new spot
-- created marks the entry that created the spot (no field changes).
create function public.spot_history_entries(p_source_id text)
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
  order by 1 desc;
end;
$$;
revoke execute on function public.spot_history_entries(text) from public,anon,authenticated;

-- Administrators' timeline (EditHistory): everything, with the
-- administrator's display name and the original report.
create function public.admin_spot_history(p_source_id text) returns jsonb
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
    from (select * from public.spot_history_entries(p_source_id) limit 200) e);
end;
$$;
revoke execute on function public.admin_spot_history(text) from public,anon;
grant execute on function public.admin_spot_history(text) to authenticated;

-- The app's history (AppHistory): the latest 10 changes of a spot riders
-- can see. Each entry is its time, its kind, whether it created the spot
-- and the public fields it changed; a field's new value only while the
-- spot still holds it. Nothing about who: no actor, report, reporter or
-- note. Rejected reports changed nothing and are left out, as are entries
-- that changed only fields riders cannot see.
create function public.spot_history(p_source_id text) returns jsonb
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
  return (select coalesce(jsonb_agg(jsonb_build_object('at',p.at,'kind',p.kind,'created',p.created,'changes',p.changes)
      order by p.at desc),'[]'::jsonb)
    from (select * from (
      select e.at,e.kind,e.created,
        (select coalesce(jsonb_agg(case when v_current->(c->>'field') is not distinct from c->'after'
            then jsonb_build_object('field',c->>'field','after',c->'after')
            else jsonb_build_object('field',c->>'field') end order by n),'[]'::jsonb)
          from jsonb_array_elements(e.changes) with ordinality j(c,n)
          where c->>'field'=any(public.spot_history_public_fields())) as changes
      from public.spot_history_entries(p_source_id) e
      where e.report is null or e.report->>'status'='accepted'
    ) q
    where q.created or jsonb_array_length(q.changes)>0
    order by q.at desc limit 10) p);
end;
$$;
revoke execute on function public.spot_history(text) from public;
grant execute on function public.spot_history(text) to anon,authenticated;
