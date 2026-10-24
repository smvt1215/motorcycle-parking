-- Admin Web P4 (docs/ADMIN_WEB.md「點位」): search, edit, create and promote
-- spots without the Dashboard. Every write checks is_admin() and is audited
-- in the same transaction. Hiding and restoring stay in admin_set_spot_hidden.

-- Columns an admin edits on either table; source_id and photos are not here.
create function public.admin_spot_fields(p_official boolean) returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','scooter_total']
  || case when p_official then array['source_name','source_url','effective_date','license_note']
     else array['status'] end;
$$;
revoke execute on function public.admin_spot_fields(boolean) from public,anon;

-- One list over both tables for the spots page. Security invoker: RLS still
-- decides what is visible, and admins (aal2) see hidden and future rows.
create function public.admin_spots(p_query text default '',p_kind text default null,p_state text default null,p_limit integer default 100)
returns table(source_id text,kind text,name text,city text,district text,address text,space_type text,
  state text,lat double precision,lng double precision,updated_at timestamptz)
language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare
  v_q text:='%'||replace(replace(replace(btrim(coalesce(p_query,'')),'\','\\'),'%','\%'),'_','\_')||'%';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_kind is not null and p_kind not in ('community','official')
     or p_state is not null and p_state not in ('pending','confirmed','visible','hidden') then
    raise exception 'invalid filter' using errcode='22023';
  end if;
  return query
  select * from (
    select c.id::text,'community'::text,c.name,c.city,c.district,c.address,c.space_type,c.status,c.lat,c.lng,c.updated_at
      from community_spots c
     where (p_kind is null or p_kind='community')
       and (p_state is null or c.status=p_state or (p_state='visible' and c.status<>'hidden'))
       and (c.name ilike v_q or c.address ilike v_q or c.road_segment ilike v_q or c.district ilike v_q or c.city ilike v_q)
    union all
    select 'official:'||o.id,'official',o.name,o.city,o.district,o.address,o.space_type,
           case when o.hidden then 'hidden' else 'visible' end,o.lat,o.lng,o.updated_at
      from official_heavy_spots o
     where (p_kind is null or p_kind='official')
       and (p_state is null or (p_state='hidden')=o.hidden and p_state in ('visible','hidden'))
       and (o.name ilike v_q or o.address ilike v_q or o.road_segment ilike v_q or o.district ilike v_q or o.city ilike v_q)
  ) s
  order by s.updated_at desc
  limit least(greatest(coalesce(p_limit,100),1),200);
end;
$$;
revoke execute on function public.admin_spots(text,text,text,integer) from public,anon;
grant execute on function public.admin_spots(text,text,text,integer) to authenticated;

-- Create (p_source_id null, p_values.kind = community|official) or edit one
-- spot. An edit names the updated_at the form was opened with; a newer row
-- means someone else changed it, and the edit is refused rather than
-- silently overwriting their work.
create function public.admin_upsert_spot(p_source_id text,p_values jsonb,p_base_updated_at timestamptz default null,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_values jsonb:=coalesce(p_values,'{}'::jsonb)-'kind';
  v_note text:=coalesce(p_note,'');
  v_official boolean; v_target uuid; v_bad text; v_before jsonb; v_after jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_values,'{}'::jsonb))<>'object' or char_length(v_note)>500 then
    raise exception 'invalid spot change' using errcode='22023';
  end if;
  if p_source_id is null then
    v_official:=p_values->>'kind'='official';
    if coalesce(p_values->>'kind','') not in ('community','official') then
      raise exception 'kind must be community or official' using errcode='22023';
    end if;
  else
    v_official:=p_source_id like 'official:%';
    v_target:=case when v_official and substr(p_source_id,10) ~* '^[0-9a-f-]{36}$' then substr(p_source_id,10)::uuid
                   when not v_official and p_source_id ~* '^[0-9a-f-]{36}$' then p_source_id::uuid end;
    if v_target is null then raise exception 'invalid spot id' using errcode='22023'; end if;
  end if;
  select k into v_bad from jsonb_object_keys(v_values) k where k<>all(public.admin_spot_fields(v_official)) limit 1;
  if v_bad is not null then raise exception 'field % cannot be changed here',v_bad using errcode='22023'; end if;
  -- Hiding has its own audited RPC; community status here is only existence.
  if not v_official and v_values ? 'status' and v_values->>'status' not in ('pending','confirmed') then
    raise exception 'use admin_set_spot_hidden to hide or restore' using errcode='22023';
  end if;
  if v_official and (v_values ? 'source_url' or p_source_id is null)
     and coalesce(v_values->>'source_url','') !~ '^https://' then
    raise exception 'official spots need an https source_url' using errcode='22023';
  end if;
  if v_official and (v_values ? 'source_name' or p_source_id is null)
     and btrim(coalesce(v_values->>'source_name',''))='' then
    raise exception 'official spots need a source_name' using errcode='22023';
  end if;

  if p_source_id is null then
    if v_official then
      if v_values->>'effective_date' is null then
        raise exception 'official spots need an effective_date' using errcode='22023';
      end if;
      insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note)
        select r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),coalesce(r.note,''),
          r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),coalesce(r.road_segment,''),
          coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),r.scooter_total,
          r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,'')
        from jsonb_populate_record(null::official_heavy_spots,v_values) r
        returning to_jsonb(official_heavy_spots.*) into v_after;
    else
      insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status)
        select auth.uid(),'community',r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),
          coalesce(r.note,''),r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),
          coalesce(r.road_segment,''),coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),
          r.scooter_total,coalesce(r.status,'pending')
        from jsonb_populate_record(null::community_spots,v_values) r
        returning to_jsonb(community_spots.*)-'location' into v_after;
    end if;
  else
    if p_base_updated_at is null then
      raise exception 'an edit needs the version it was opened with' using errcode='22023';
    end if;
    if v_official then
      select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_target for update;
    else
      select to_jsonb(c)-'location' into v_before from community_spots c where c.id=v_target for update;
    end if;
    if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
    if (v_before->>'updated_at')::timestamptz<>p_base_updated_at then
      raise exception 'spot changed since it was opened' using errcode='40001';
    end if;
    if v_official then
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.source_name,r.source_url,r.effective_date,r.license_note,now()
          from jsonb_populate_record(o,v_values) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    else
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.status,now()
          from jsonb_populate_record(c,v_values) r)
        where c.id=v_target returning to_jsonb(c)-'location' into v_after;
    end if;
  end if;

  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),case when p_source_id is null then 'create_spot' else 'update_spot' end,
    case when v_official then 'official_heavy_spots' else 'community_spots' end,v_after->>'id',v_before,v_after,v_note);
  return v_after||jsonb_build_object('source_id',case when v_official then 'official:' else '' end||(v_after->>'id'));
end;
$$;
revoke execute on function public.admin_upsert_spot(text,jsonb,timestamptz,text) from public,anon;
grant execute on function public.admin_upsert_spot(text,jsonb,timestamptz,text) to authenticated;

-- A community spot confirmed against official data becomes an official one.
-- Eligibility trusts official spots fully, so nothing riders entered carries
-- over as trusted: both eligibility flags start unconfirmed unless the admin
-- sets them here, and a traceable official source is required. The community
-- row is hidden, not deleted, and its full snapshot goes into the audit log.
create function public.admin_promote_spot(p_source_id text,p_values jsonb,p_base_updated_at timestamptz,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_values jsonb:=coalesce(p_values,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_community community_spots; v_bad text; v_after jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_source_id is null or p_source_id !~* '^[0-9a-f-]{36}$' or jsonb_typeof(v_values)<>'object' or char_length(v_note)>500 then
    raise exception 'invalid promotion' using errcode='22023';
  end if;
  select k into v_bad from jsonb_object_keys(v_values) k where k<>all(public.admin_spot_fields(true)) limit 1;
  if v_bad is not null then raise exception 'field % cannot be set here',v_bad using errcode='22023'; end if;
  if coalesce(v_values->>'source_url','') !~ '^https://' or btrim(coalesce(v_values->>'source_name',''))=''
     or v_values->>'effective_date' is null then
    raise exception 'promotion needs source_name, an https source_url and effective_date' using errcode='22023';
  end if;
  select * into v_community from community_spots where id=p_source_id::uuid for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  if v_community.updated_at<>p_base_updated_at then
    raise exception 'spot changed since it was opened' using errcode='40001';
  end if;
  if v_community.status='hidden' then
    raise exception 'restore the spot before promoting it' using errcode='22023';
  end if;

  insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
      facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,parking_zones,
      source_name,source_url,effective_date,license_note)
    select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
      -- Only what the admin states in this call; never the rider's values.
      case when v_values ? 'scooter_allowed' then (v_values->>'scooter_allowed')::boolean end,
      case when v_values ? 'heavy_allowed' then (v_values->>'heavy_allowed')::boolean end,
      r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
      v_community.parking_zones,r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,'')
    from jsonb_populate_record(
      null::official_heavy_spots,
      (to_jsonb(v_community)-'id'-'user_id'-'location'-'source'-'source_name'-'source_url'-'license_note'
        -'status'-'last_confirmed_at'-'created_at'-'available'-'photo_urls'-'updated_at')||v_values) r
    returning to_jsonb(official_heavy_spots.*) into v_after;

  update community_spots set status='hidden',updated_at=now() where id=v_community.id;
  -- Open reports follow the spot; their snapshots still flag changed fields.
  update moderation_queue set source_id='official:'||(v_after->>'id')
   where source_id=v_community.id::text and status='pending';

  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'promote_spot','community_spots',v_community.id::text,
    to_jsonb(v_community)-'location',jsonb_build_object('official',v_after),v_note);
  return v_after||jsonb_build_object('source_id','official:'||(v_after->>'id'));
end;
$$;
revoke execute on function public.admin_promote_spot(text,jsonb,timestamptz,text) from public,anon;
grant execute on function public.admin_promote_spot(text,jsonb,timestamptz,text) to authenticated;
