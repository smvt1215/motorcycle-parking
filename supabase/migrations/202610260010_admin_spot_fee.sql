-- Structured fees in Admin Web (docs/ADMIN_WEB.md「點位」). The app shows a
-- spot's structured `fee` before its `fee_note` text, so an admin who could
-- only edit the text changed nothing riders saw once a fee existed. The spot
-- form now edits `fee` with the shared FeeEditor and writes the text that
-- lib/models/fee.dart's feeNoteOf builds from it; this keeps the two in step.
-- parking_zones stay outside the admin edit list (their fees are already
-- checked by valid_zone_fees on both tables).

-- The fee_note text of a valid fee, as feeNoteOf in lib/models/fee.dart
-- writes it. Change both together; pgTAP pins the same sentences.
create function public.fee_rate_text(p_rate jsonb) returns text
language sql immutable set search_path='' as $$
  select case p_rate->>'mode'
    when 'free' then '免費'
    when 'posted' then '依現場公告'
    when 'hourly' then
      case when m=60 then '每小時' when m%60=0 then '每 '||(m/60)||' 小時' else '每 '||m||' 分鐘' end
      ||' '||a||' 元'||coalesce('，當日上限 '||cap||' 元','')
    when 'per_visit' then
      '每次 '||a||' 元'||coalesce('（'||case when lim%60=0 then (lim/60)||' 小時' else lim||' 分鐘' end||'內）','')
    when 'daily' then '每日 '||a||' 元'
    when 'same_as_scooter' then '比照機車費率'
    when 'same_as_car' then '比照汽車費率'
  end
  from (select coalesce((p_rate->>'per_minutes')::numeric::integer,60) as m,
    coalesce((p_rate->>'amount')::numeric::integer,0) as a,
    (p_rate->>'daily_cap')::numeric::integer as cap,
    (p_rate->>'max_minutes')::numeric::integer as lim) v;
$$;

create function public.fee_note_of(p_fee jsonb) returns text
language sql immutable set search_path='' as $$
  select case
    when s is null and h is null then '請依現場公告'
    when h is null then s||'（大型重機費率未確認）'
    when s is null then '大型重機'||h
    when p_fee->'heavy'->>'mode' in ('same_as_scooter','same_as_car') then s||'（大型重機'||h||'）'
    else '機車'||s||'；大型重機'||h
  end
  from (select public.fee_rate_text(p_fee->'scooter') as s,public.fee_rate_text(p_fee->'heavy') as h) v;
$$;

-- Whether a spot row (or the values of a new one) keeps fee_note as the text
-- of its fee. Without a fee the text is free, as for legacy rows.
create function public.fee_note_matches(p_row jsonb) returns boolean
language sql immutable set search_path='' as $$
  select jsonb_typeof(p_row->'fee') is distinct from 'object'
    or coalesce(p_row->>'fee_note','請依現場公告')=public.fee_note_of(p_row->'fee');
$$;
revoke execute on function public.fee_note_matches(jsonb) from public,anon;

-- 202610250001_admin_spots.sql's list plus fee, on both tables. Promotion
-- reads the same list for official values; its table check covers a fee.
create or replace function public.admin_spot_fields(p_official boolean) returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','scooter_total','fee']
  || case when p_official then array['source_name','source_url','effective_date','license_note']
     else array['status'] end;
$$;

-- 202610250080_admin_verified_eligibility.sql's body (its set_config calls
-- for the verification trigger unchanged) plus: fee is checked, written on
-- create and edit, and fee_note must be its text whenever the spot has one.
create or replace function public.admin_upsert_spot(p_source_id text,p_values jsonb,p_base_updated_at timestamptz default null,p_note text default '')
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
  -- The table check holds too; this names the problem for the admin site.
  if jsonb_typeof(v_values->'fee')<>'null' and not public.valid_fee(v_values->'fee') then
    raise exception 'invalid fee' using errcode='22023';
  end if;
  -- Hiding has its own audited RPC; community status here is only existence.
  if not v_official and v_values ? 'status' and v_values->>'status' not in ('pending','confirmed') then
    raise exception 'use admin_set_spot_hidden to hide or restore' using errcode='22023';
  end if;
  -- Tell the verification trigger which vehicle fields this edit states,
  -- even when a value equals the stored one.
  perform set_config('app.admin_vehicle_fields',(select coalesce(string_agg(k,','),'') from jsonb_object_keys(v_values) k
    where k in ('scooter_allowed','heavy_allowed','parking_access')),true);
  if v_official and (v_values ? 'source_url' or p_source_id is null)
     and coalesce(v_values->>'source_url','') !~ '^https://' then
    raise exception 'official spots need an https source_url' using errcode='22023';
  end if;
  if v_official and (v_values ? 'source_name' or p_source_id is null)
     and btrim(coalesce(v_values->>'source_name',''))='' then
    raise exception 'official spots need a source_name' using errcode='22023';
  end if;

  if p_source_id is null then
    if not public.fee_note_matches(v_values) then
      raise exception 'fee_note must be the text of fee' using errcode='22023';
    end if;
    if v_official then
      if v_values->>'effective_date' is null then
        raise exception 'official spots need an effective_date' using errcode='22023';
      end if;
      insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee)
        select r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),coalesce(r.note,''),
          r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),coalesce(r.road_segment,''),
          coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),r.scooter_total,
          r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),r.fee
        from jsonb_populate_record(null::official_heavy_spots,v_values) r
        returning to_jsonb(official_heavy_spots.*) into v_after;
    else
      insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee)
        select auth.uid(),'community',r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),
          coalesce(r.note,''),r.scooter_allowed,r.heavy_allowed,r.facility_type,r.parking_access,coalesce(r.address,''),
          coalesce(r.road_segment,''),coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),
          r.scooter_total,coalesce(r.status,'pending'),r.fee
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
    -- Checked on the row as it will be, and only when this edit touches the
    -- fee or its text: an untouched imported row never blocks other edits.
    if (v_values ? 'fee' or v_values ? 'fee_note') and not public.fee_note_matches(v_before||v_values) then
      raise exception 'fee_note must be the text of fee' using errcode='22023';
    end if;
    if v_official then
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.source_name,r.source_url,r.effective_date,r.license_note,r.fee,now()
          from jsonb_populate_record(o,v_values) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    else
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.status,r.fee,now()
          from jsonb_populate_record(c,v_values) r)
        where c.id=v_target returning to_jsonb(c)-'location' into v_after;
    end if;
  end if;

  perform set_config('app.admin_vehicle_fields','',true);
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),case when p_source_id is null then 'create_spot' else 'update_spot' end,
    case when v_official then 'official_heavy_spots' else 'community_spots' end,v_after->>'id',v_before,v_after,v_note);
  return v_after||jsonb_build_object('source_id',case when v_official then 'official:' else '' end||(v_after->>'id'));
end;
$$;
