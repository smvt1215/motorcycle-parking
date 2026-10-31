-- 停放資格取消「未確認」：官方未標示 not_stated（#201）。
--
-- 1. parking_contract() gains eligibility (supabase/functions/_shared/
--    parking_contract.json): a vehicle's eligibility is true, false or
--    not_stated; null stays only as old data's 待確認. valid_condition()
--    takes not_stated as a zone allow value; zone_condition_consistent()
--    lets a zone that says not_stated carry no access (it writes none back;
--    old builds read the zone as unconfirmed). Copied from
--    supabase/contract/parking_contract.sql.
-- 2. Both spot tables get scooter_not_stated and heavy_not_stated (boolean,
--    default false): true says the official data does not state the
--    vehicle, and the boolean beside it is then null, so old builds read it
--    as unconfirmed. A trigger keeps the pair in step: newly marking
--    not_stated clears the boolean, a boolean clears not_stated.
-- 3. Writes never clear a vehicle (eligibility_values_ok()): admin edits and
--    promotions leave both vehicles stated, old rows included (編輯舊資料時
--    必須補填; an edit of the closure or the status alone is exempt); a rider's
--    new spot states both (a street spot only true or false) and every zone
--    it adds; a suggestion's zone patch, and the review applying it, leaves
--    each zone it changes stated. Untouched zones keep their old values.
-- 4. Official imports read a vehicle the file leaves out as not_stated
--    (官方、路外含營運業者公告沒寫＝官方未標示); a vehicle's flag and its
--    not_stated are kept or replaced together, as a fee and its text.
-- 5. public_spots, official_viewport_spots_v3 and the history carry the
--    two columns.


-- parking_contract(), valid_condition() and zone_condition_consistent() as
-- tool/gen_contract_sql.py writes them.
create or replace function public.parking_contract() returns jsonb
language sql immutable set search_path='' as $contract$
  select $json${"version":1,"space_types":["paidMotorcycle","freeMotorcycle","heavyOnly","car","offStreet","disabledMotorcycle","timedMotorcycle","flexShared","evMotorcycle"],"access_kinds":["scooterOnly","scooterHeavy","heavyCar","noMotorcycle","heavyOnly"],"eligibility":{"vehicles":["scooter","heavy"],"not_stated":"not_stated","spot_keys":{"scooter":{"allowed":"scooter_allowed","not_stated":"scooter_not_stated"},"heavy":{"allowed":"heavy_allowed","not_stated":"heavy_not_stated"}}},"placement":{"off_street_space_types":["offStreet"],"off_street_facility_types":["multiStorey","underground","surface"],"facility_types":["multiStorey","underground","surface","roadside"]},"time":{"pattern":"^([01][0-9]|2[0-3]):[0-5][0-9]$","days":["all","weekday","holiday"],"weekdays":["mon","tue","wed","thu","fri","sat","sun"],"optional_pair":["from","to"]},"date":{"pattern":"^(19|[2-9][0-9])[0-9]{2}-[0-9]{2}-[0-9]{2}$"},"condition":{"keys":["bay","use","share","charge","limits","schedule","basis"],"zone_keys":["allow"],"bay":["motorcycle","heavy","car"],"use":["usual","share"],"share":{"scooter_heavy":"motorcycle","car_motorcycle":"car"},"charge":["toll","free"],"limits":{"time_limit":{"required":[],"optional":{"max_minutes":{"min":1,"max":1440}}},"special_vehicle":{"required":["vehicle"],"optional":{}},"ev_only":{"required":[],"optional":{}}},"special_vehicles":["disabled_modified"],"street_charge_optional_with":["time_limit","special_vehicle","ev_only"],"allow_keys":["scooter","heavy"],"allow_values":"boolean 或 eligibility.not_stated","schedule":{"keys":["days","from","to","vehicles"],"max_entries":8,"vehicles":["scooter","heavy","car"]},"basis":{"keys":["source_url","evidence_id","effective_date","expires_on"],"required_one_of":["source_url","evidence_id"],"reserved":["evidence_id"],"source_url":{"pattern":"^https://\\S+$","max_length":2048,"length_unit":"utf16"}}},"zone":{"area":["motorcycle","car","heavy","mixed"],"id_pattern":"^[a-z0-9_-]{1,32}$"},"segment":{"keys":["id","name","side","range","condition","total","guide","evidence_url"],"max_entries":30,"sides":["east","west","south","north","both"],"name_max_length":40,"range_max_length":100,"guide_max_length":500,"total":{"min":1,"max":9999}},"bay_kinds":{"order":["motorcycle","scooter_heavy","heavy","car_motorcycle","car","disabled","ev"],"rules":[{"when":{"limit":"special_vehicle"},"bay_kind":"disabled"},{"when":{"limit":"ev_only"},"bay_kind":"ev"},{"when":{"share":"car_motorcycle"},"bay_kind":"car_motorcycle"},{"when":{"share":"scooter_heavy"},"bay_kind":"scooter_heavy"},{"when":{"bay":"heavy"},"bay_kind":"heavy"},{"when":{"bay":"car"},"bay_kind":"car"},{"when":{"bay":"motorcycle"},"bay_kind":"motorcycle"}]},"conversion":{"from_space_type":{"paidMotorcycle":{"bay":"motorcycle","use":"usual","charge":"toll"},"freeMotorcycle":{"bay":"motorcycle","use":"usual","charge":"free"},"heavyOnly":{"bay":"heavy","use":"usual"},"car":{"bay":"car","use":"usual"},"offStreet":null,"disabledMotorcycle":{"bay":"motorcycle","limits":[{"kind":"special_vehicle","vehicle":"disabled_modified"}]},"timedMotorcycle":{"bay":"motorcycle","use":"usual","limits":[{"kind":"time_limit"}]},"flexShared":{"bay":"car","use":"share","share":"car_motorcycle"},"evMotorcycle":{"bay":"motorcycle","limits":[{"kind":"ev_only"}]}},"from_access":{"scooterOnly":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}},"scooterHeavy":{"bay":"motorcycle","use":"share","share":"scooter_heavy","allow":{"scooter":true,"heavy":true}},"heavyCar":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}},"heavyOnly":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}},"noMotorcycle":{"allow":{"scooter":false,"heavy":false}}},"to_space_type":[{"when":{"placement":"off_street"},"space_type":"offStreet"},{"when":{"limit":"special_vehicle"},"space_type":"disabledMotorcycle"},{"when":{"limit":"ev_only"},"space_type":"evMotorcycle"},{"when":{"share":"car_motorcycle"},"space_type":"flexShared"},{"when":{"limit":"time_limit"},"space_type":"timedMotorcycle"},{"when":{"bay":"heavy"},"space_type":"heavyOnly"},{"when":{"bay":"car"},"space_type":"car"},{"when":{"bay":"motorcycle","charge":"toll"},"space_type":"paidMotorcycle"},{"when":{"bay":"motorcycle","charge":"free"},"space_type":"freeMotorcycle"}],"to_access":"allow 與 from_access 的 allow 相同，且 from_access 有 bay 時 bay 也相同","legacy_safe":{"unsafe_keys":["schedule"],"unsafe_basis_keys":["expires_on"],"lossy_share":"scooter_heavy","lossy_limit_keys":["max_minutes"],"assumed_charge":{"timedMotorcycle":"toll"},"lossy_when_unconfirmed":["bay","use","share","charge"]}},"fee":{"max_bytes":8192,"vehicles":["scooter","heavy","car"],"follow":{"vehicles":["heavy"],"modes":["same_as_scooter","same_as_car"],"optional":{"factor_pct":{"min":100,"max":1000}}},"modes":{"free":{"required":{},"optional":{}},"posted":{"required":{},"optional":{}},"hourly":{"required":{"amount":{"min":0,"max":10000},"per_minutes":{"min":1,"max":1440}},"optional":{"unit_minutes":{"min":1,"max":"per_minutes"},"free_minutes":{"min":1,"max":1440},"daily_cap":{"min":0,"max":10000},"cap_reset":"cap_reset"}},"per_visit":{"required":{"amount":{"min":0,"max":10000}},"optional":{"max_minutes":{"min":1,"max":1440},"renew":"renew","extension":"extension"}},"daily":{"required":{"amount":{"min":0,"max":10000}},"optional":{"cap_reset":"cap_reset"}},"by_time":{"required":{"periods":"periods"},"optional":{"cross_period":"cross_period"}}},"enums":{"cap_reset":["calendar_day","rolling_24h","per_entry"],"renew":["none","midnight"],"cross_period":["each_period","entry_only"]},"extension":{"required":{"amount":{"min":0,"max":10000},"max_times":{"min":1,"max":10}},"optional":{"minutes":{"min":1,"max":1440}}},"periods":{"max_entries":6,"keys":["days","from","to","rate"],"nested_modes":["free","posted","hourly","per_visit","daily"]}},"fee_plans":{"max_entries":12,"keys":["id","name","fee"],"id_pattern":"^[a-z0-9_-]{1,20}$","name_max_length":20}}$json$::jsonb;
$contract$;

create or replace function public.valid_condition(p_condition jsonb,p_zone boolean default false) returns boolean
language plpgsql immutable set search_path='' as $$
declare
  p jsonb:=p_condition;
  c jsonb:=public.parking_contract()->'condition';
  l jsonb; v jsonb; spec jsonb; f record; kinds text[]:='{}';
begin
  if jsonb_typeof(p) is distinct from 'object' or p='{}'::jsonb then return false; end if;
  if exists(select 1 from jsonb_object_keys(p) k
      where not (c->'keys' ? k or (p_zone and c->'zone_keys' ? k))) then return false; end if;
  if (p ? 'bay' and not public.contract_str_in(p->'bay',c->'bay'))
    or (p ? 'use' and not public.contract_str_in(p->'use',c->'use'))
    or (p ? 'share' and not (jsonb_typeof(p->'share')='string' and c->'share' ? (p->>'share')))
    or (p ? 'charge' and not public.contract_str_in(p->'charge',c->'charge')) then return false; end if;
  if not p_zone and not p ? 'bay' then return false; end if;
  if (p ? 'share')<>coalesce(p->>'use'='share',false) then return false; end if;
  if p ? 'share' and (p->>'bay') is distinct from (c->'share'->>(p->>'share')) then return false; end if;

  if p ? 'limits' then
    if jsonb_typeof(p->'limits') is distinct from 'array'
      or jsonb_array_length(p->'limits') not between 1 and (select count(*) from jsonb_object_keys(c->'limits'))
    then return false; end if;
    for l in select e from jsonb_array_elements(p->'limits') e loop
      if jsonb_typeof(l) is distinct from 'object' or jsonb_typeof(l->'kind') is distinct from 'string'
        or not c->'limits' ? (l->>'kind') or (l->>'kind')=any(kinds) then return false; end if;
      kinds:=kinds||(l->>'kind');
      spec:=c->'limits'->(l->>'kind');
      for f in select key,value from jsonb_each(l) loop
        continue when f.key='kind' or spec->'required' ? f.key;
        if not spec->'optional' ? f.key or not public.contract_whole(f.value,
            (spec->'optional'->f.key->>'min')::numeric,(spec->'optional'->f.key->>'max')::numeric)
        then return false; end if;
      end loop;
      if exists(select 1 from jsonb_array_elements_text(spec->'required') r where not l ? r) then return false; end if;
      if l ? 'vehicle' and not public.contract_str_in(l->'vehicle',c->'special_vehicles') then return false; end if;
    end loop;
  end if;
  if not p_zone and p->>'bay'='motorcycle' and not p ? 'charge'
    and not kinds && array(select jsonb_array_elements_text(c->'street_charge_optional_with'))
  then return false; end if;

  if p ? 'allow' then
    v:=p->'allow';
    if jsonb_typeof(v) is distinct from 'object' or v='{}'::jsonb
      -- A value is true, false or not_stated (#201, eligibility.not_stated).
      or exists(select 1 from jsonb_each(v) e where not c->'allow_keys' ? e.key
        or (jsonb_typeof(e.value)<>'boolean' and e.value is distinct from public.parking_contract()->'eligibility'->'not_stated'))
    then return false; end if;
    if v->'scooter'='true'::jsonb and p->>'bay'='heavy' then return false; end if;
  end if;

  if p ? 'schedule' then
    if jsonb_typeof(p->'schedule') is distinct from 'array'
      or jsonb_array_length(p->'schedule') not between 1 and (c->'schedule'->>'max_entries')::integer
    then return false; end if;
    for l in select e from jsonb_array_elements(p->'schedule') e loop
      if not public.contract_slot_keys(l,c->'schedule'->'keys') or not public.contract_slot_times(l)
        or not public.contract_subset(l->'vehicles',c->'schedule'->'vehicles') then return false; end if;
    end loop;
  end if;

  if p ? 'basis' then
    v:=p->'basis';
    if jsonb_typeof(v) is distinct from 'object'
      or exists(select 1 from jsonb_object_keys(v) k where not c->'basis'->'keys' ? k) then return false; end if;
    -- Reserved until photo evidence ships (verification plan P2).
    if exists(select 1 from jsonb_array_elements_text(c->'basis'->'reserved') r
        where coalesce(jsonb_typeof(v->r),'null')<>'null') then return false; end if;
    if not exists(select 1 from jsonb_array_elements_text(c->'basis'->'required_one_of') r
        where coalesce(jsonb_typeof(v->r),'null')<>'null') then return false; end if;
    if v ? 'source_url' and not coalesce(jsonb_typeof(v->'source_url')='string'
        -- UTF-16 code units, as Dart and JS count: characters outside the BMP count twice.
        and char_length(v->>'source_url')+regexp_count(v->>'source_url','[\U00010000-\U0010FFFF]')
          <=(c->'basis'->'source_url'->>'max_length')::integer
        and (v->>'source_url') ~ (c->'basis'->'source_url'->>'pattern'),false) then return false; end if;
    if (coalesce(jsonb_typeof(v->'effective_date'),'null')<>'null' and not public.contract_date(v->'effective_date'))
      or (coalesce(jsonb_typeof(v->'expires_on'),'null')<>'null' and not public.contract_date(v->'expires_on'))
    then return false; end if;
    if jsonb_typeof(v->'effective_date')='string' and jsonb_typeof(v->'expires_on')='string'
      and (v->>'expires_on') collate "C"<=(v->>'effective_date') collate "C" then return false; end if;
  end if;
  return true;
end;
$$;

create or replace function public.zone_condition_consistent(p_zone jsonb) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p_zone->'condition'),'null')='null'
    or case when jsonb_typeof(p_zone->'condition'->'allow')='object' and exists(
        select 1 from jsonb_each(p_zone->'condition'->'allow') e
        where e.value=(public.parking_contract()->'eligibility'->'not_stated'))
      then coalesce(jsonb_typeof(p_zone->'access'),'null')='null'
        and p_zone->'condition'->'allow' ?& array['scooter','heavy']
      else jsonb_typeof(p_zone->'access')='string'
        and coalesce((p_zone->>'access')=public.condition_legacy_access(p_zone->'condition'),false) end;
$$;

-- ---- Spot-level not_stated.
alter table public.community_spots
  add column scooter_not_stated boolean not null default false,
  add column heavy_not_stated boolean not null default false,
  add constraint community_spots_not_stated_check
    check (not (scooter_not_stated and scooter_allowed is not null) and not (heavy_not_stated and heavy_allowed is not null));
alter table public.official_heavy_spots
  add column scooter_not_stated boolean not null default false,
  add column heavy_not_stated boolean not null default false,
  add constraint official_heavy_spots_not_stated_check
    check (not (scooter_not_stated and scooter_allowed is not null) and not (heavy_not_stated and heavy_allowed is not null));
grant select (scooter_not_stated,heavy_not_stated) on public.community_spots to anon,authenticated;

-- Marking a vehicle not_stated clears its boolean; stating a boolean
-- clears not_stated. Sorts before the other BEFORE triggers that read the
-- booleans (vehicle_verification).
create function public.sync_not_stated() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.scooter_not_stated and (tg_op='INSERT' or not old.scooter_not_stated) then new.scooter_allowed:=null;
  elsif new.scooter_allowed is not null then new.scooter_not_stated:=false; end if;
  if new.heavy_not_stated and (tg_op='INSERT' or not old.heavy_not_stated) then new.heavy_allowed:=null;
  elsif new.heavy_allowed is not null then new.heavy_not_stated:=false; end if;
  return new;
end;
$$;
create trigger community_spots_eligibility before insert or update on public.community_spots
  for each row execute function public.sync_not_stated();
create trigger official_heavy_spots_eligibility before insert or update on public.official_heavy_spots
  for each row execute function public.sync_not_stated();

-- The vehicle keys of a write (an object of spot fields): each vehicle it
-- names is true or false (x_allowed), or not_stated (x_not_stated true,
-- x_allowed null or left out). Clearing a vehicle (x_allowed null alone) or
-- x_not_stated false without a boolean says nothing and is refused.
create function public.eligibility_values_ok(p jsonb) returns boolean
language sql immutable set search_path='' as $$
  select not exists(select 1 from unnest(array['scooter','heavy']) v
    cross join lateral (select p->(v||'_allowed') a,p->(v||'_not_stated') n) x
    where (x.a is not null and jsonb_typeof(x.a) not in ('boolean','null'))
      or (x.n is not null and jsonb_typeof(x.n)<>'boolean')
      or (x.n='true'::jsonb and coalesce(jsonb_typeof(x.a),'null')<>'null')
      or (x.n='false'::jsonb and jsonb_typeof(x.a) is distinct from 'boolean')
      or (jsonb_typeof(x.a)='null' and x.n is distinct from 'true'::jsonb));
$$;

-- Whether a spot (a row or a write as jsonb) states both vehicles: true,
-- false or not_stated.
create function public.eligibility_stated(p jsonb) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p->'scooter_allowed')='boolean' or p->'scooter_not_stated'='true'::jsonb,false)
    and coalesce(jsonb_typeof(p->'heavy_allowed')='boolean' or p->'heavy_not_stated'='true'::jsonb,false);
$$;

-- Whether a zone states both vehicles: by its access, or by a condition
-- whose allow names both (true, false or not_stated).
create function public.zone_eligibility_stated(p_zone jsonb) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p_zone->'access')='string',false)
    or coalesce(jsonb_typeof(p_zone->'condition'->'allow')='object'
      and p_zone->'condition'->'allow' ?& array['scooter','heavy'],false);
$$;

-- Whether each zone a patch (#188, entries_patch()) adds or changes states
-- both vehicles once applied (p_merged): only the zones a rider changes
-- must be filled in; the others keep their old values.
create function public.zone_patch_stated(p_patch jsonb,p_merged jsonb) returns boolean
language sql immutable set search_path='' as $$
  select not exists(select 1 from jsonb_array_elements(case when jsonb_typeof(p_patch)='array' then p_patch else '[]'::jsonb end) e
    where not coalesce(e->'removed'='true'::jsonb,false)
      and not coalesce(public.zone_eligibility_stated(case when e ? 'id'
        then (select m from jsonb_array_elements(case when jsonb_typeof(p_merged)='array' then p_merged else '[]'::jsonb end) m
          where m->>'id'=e->>'id' limit 1) else e end),false));
$$;

-- ---- Writers carry the two columns and keep vehicles stated.

CREATE OR REPLACE FUNCTION public.admin_spot_fields(p_official boolean)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','scooter_not_stated','heavy_not_stated','facility_type','facility_types','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','scooter_total','fee','condition','zones_complete',
    'parking_zones','parking_segments','fee_plans','fee_plan','closure']
  || case when p_official then array['source_name','source_url','effective_date','license_note']
     else array['status'] end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_upsert_spot(p_source_id text, p_values jsonb, p_base_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
  if jsonb_typeof(v_values->'condition')<>'null' and not public.valid_condition(v_values->'condition') then
    raise exception 'invalid condition' using errcode='22023';
  end if;
  if v_values ? 'parking_zones' and not public.valid_zones(v_values->'parking_zones') then
    raise exception 'invalid parking_zones' using errcode='22023';
  end if;
  if v_values ? 'parking_segments' and not public.valid_segments(v_values->'parking_segments') then
    raise exception 'invalid parking_segments' using errcode='22023';
  end if;
  if v_values ? 'closure' and not public.valid_closure(v_values->'closure') then
    raise exception 'invalid closure' using errcode='22023';
  end if;
  -- Eligibility (#201): true, false or not_stated; never cleared.
  if not public.eligibility_values_ok(v_values) then
    raise exception 'invalid eligibility: true, false or not_stated' using errcode='22023';
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
      insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure)
        select r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),coalesce(r.note,''),
          r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),r.facility_type,r.facility_types,r.parking_access,coalesce(r.address,''),coalesce(r.road_segment,''),
          coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),r.scooter_total,
          r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),r.fee,
          r.condition,coalesce(r.zones_complete,false),coalesce(r.parking_zones,'[]'::jsonb),coalesce(r.parking_segments,'[]'::jsonb),r.fee_plans,r.fee_plan,r.closure
        from jsonb_populate_record(null::official_heavy_spots,v_values) r
        returning to_jsonb(official_heavy_spots.*) into v_after;
    else
      insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure)
        select auth.uid(),'community',r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),
          coalesce(r.note,''),r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),r.facility_type,r.facility_types,r.parking_access,coalesce(r.address,''),
          coalesce(r.road_segment,''),coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),
          r.scooter_total,coalesce(r.status,'pending'),r.fee,r.condition,coalesce(r.zones_complete,false),
          coalesce(r.parking_zones,'[]'::jsonb),coalesce(r.parking_segments,'[]'::jsonb),r.fee_plans,r.fee_plan,r.closure
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
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.source_name,r.source_url,r.effective_date,r.license_note,r.fee,r.condition,r.zones_complete,
          r.parking_zones,r.parking_segments,r.fee_plans,r.fee_plan,r.closure,now()
          from jsonb_populate_record(o,v_values) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    else
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.status,r.fee,r.condition,r.zones_complete,r.parking_zones,r.parking_segments,r.fee_plans,r.fee_plan,r.closure,now()
          from jsonb_populate_record(c,v_values) r)
        where c.id=v_target returning to_jsonb(c)-'location' into v_after;
    end if;
  end if;

  -- Both vehicles stated once written, old rows too (編輯舊資料時必須補填);
  -- setting the closure or the status alone is no edit of the data.
  if not public.eligibility_stated(v_after) and exists(select 1 from jsonb_object_keys(v_values) k
      where k not in ('closure','status')) then
    raise exception 'state both vehicles: true, false or not_stated' using errcode='22023';
  end if;
  perform set_config('app.admin_vehicle_fields','',true);
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),case when p_source_id is null then 'create_spot' else 'update_spot' end,
    case when v_official then 'official_heavy_spots' else 'community_spots' end,v_after->>'id',v_before,v_after,v_note);
  return v_after||jsonb_build_object('source_id',case when v_official then 'official:' else '' end||(v_after->>'id'));
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_promote_spot(p_source_id text, p_values jsonb, p_base_updated_at timestamp with time zone, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
  -- An official spot states both vehicles (#201): the admin's call, never
  -- the rider's values, and never reset to unconfirmed.
  if not public.eligibility_values_ok(v_values) or not public.eligibility_stated(v_values) then
    raise exception 'promotion states both vehicles: true, false or not_stated' using errcode='22023';
  end if;
  select * into v_community from community_spots where id=p_source_id::uuid for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  if v_community.updated_at<>p_base_updated_at then
    raise exception 'spot changed since it was opened' using errcode='40001';
  end if;
  if v_community.status='hidden' then
    raise exception 'restore the spot before promoting it' using errcode='22023';
  end if;

  insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
      facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,parking_zones,parking_segments,
      source_name,source_url,effective_date,license_note,fee,condition,zones_complete,closure)
    select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
      -- Only what the admin states in this call; never the rider's values.
      case when v_values ? 'scooter_allowed' then (v_values->>'scooter_allowed')::boolean end,
      case when v_values ? 'heavy_allowed' then (v_values->>'heavy_allowed')::boolean end,
      coalesce((v_values->>'scooter_not_stated')::boolean,false),coalesce((v_values->>'heavy_not_stated')::boolean,false),
      r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
      v_community.parking_zones,r.parking_segments,r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),
      -- The fee moves with its fee_note text, so the two stay in step.
      r.fee,r.condition,coalesce(r.zones_complete,false),
      -- Works or a closure moves with the spot, as it stands (#116).
      r.closure
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_resolve_report(p_id uuid, p_decision text, p_patch jsonb DEFAULT '{}'::jsonb, p_note text DEFAULT ''::text, p_force boolean DEFAULT false, p_resolution_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_report moderation_queue;
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_kind text:=nullif(btrim(coalesce(p_resolution_kind,'')),'');
  v_fields text[]:=array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','scooter_not_stated','heavy_not_stated','facility_type','facility_types','parking_access','address','road_segment',
    'entrance_note','parking_guide','special_rules','fee','condition','fee_plans','fee_plan','closure',
    'parking_zones','parking_segments'];
  v_table text; v_target uuid; v_bad text; v_before jsonb; v_after jsonb;
  v_conflict boolean:=false;
  v_list text; v_merged jsonb;
  -- The fee_plans the review page built a plan edit on ({"plans": …}); not
  -- a column, so it leaves the patch before the field check.
  v_seen jsonb:=p_patch->'fee_plans_seen';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_decision is null or p_decision not in ('accepted','rejected') then
    raise exception 'invalid decision' using errcode='22023';
  end if;
  if jsonb_typeof(v_patch)<>'object' or char_length(v_note)>500 then
    raise exception 'invalid resolution' using errcode='22023';
  end if;
  if v_kind is not null and v_kind not in ('wrong','duplicate','insufficient','outdated','abuse','other') then
    raise exception 'invalid resolution kind' using errcode='22023';
  end if;
  if p_decision='rejected' and v_kind is null then
    raise exception 'a rejection needs a resolution kind' using errcode='22023';
  end if;
  -- "Other" says nothing by itself; the note is the reason.
  if v_kind='other' and btrim(v_note)='' then
    raise exception 'resolution kind other needs a note' using errcode='22023';
  end if;
  select * into v_report from moderation_queue where id=p_id for update;
  if not found then raise exception 'report not found' using errcode='22023'; end if;
  if v_report.status<>'pending' then raise exception 'report already resolved' using errcode='22023'; end if;
  v_patch:=v_patch-'fee_plans_seen';
  if p_decision='rejected' and v_patch<>'{}'::jsonb then
    raise exception 'a rejected report changes no spot' using errcode='22023';
  end if;

  if v_patch ? 'closure' and not public.valid_closure(v_patch->'closure') then
    raise exception 'invalid closure' using errcode='22023';
  end if;
  -- Eligibility (#201): true, false or not_stated; never cleared.
  if not public.eligibility_values_ok(v_patch) then
    raise exception 'invalid eligibility: true, false or not_stated' using errcode='22023';
  end if;

  if v_patch<>'{}'::jsonb then
    if v_report.source_id like 'official:%' then
      v_table:='official_heavy_spots';
      v_fields:=v_fields||'hidden'::text;
      v_target:=case when substr(v_report.source_id,10) ~* '^[0-9a-f-]{36}$' then substr(v_report.source_id,10)::uuid end;
    else
      v_table:='community_spots';
      -- Community spots are hidden or restored through status, official ones through hidden.
      v_fields:=v_fields||'status'::text;
      v_target:=case when v_report.source_id ~* '^[0-9a-f-]{36}$' then v_report.source_id::uuid end;
    end if;
    select k into v_bad from jsonb_object_keys(v_patch) k where k<>all(v_fields) limit 1;
    if v_bad is not null then raise exception 'field % cannot be changed here',v_bad using errcode='22023'; end if;
    -- Adopting a vehicle field verifies it even when the value is unchanged.
    perform set_config('app.admin_vehicle_fields',(select coalesce(string_agg(k,','),'') from jsonb_object_keys(v_patch) k
      where k in ('scooter_allowed','heavy_allowed','parking_access')),true);

    if v_table='community_spots' then
      select to_jsonb(c)-'user_id'-'location' into v_before from community_spots c where c.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      -- Only the fields this patch writes count: votes or other edits that
      -- leave them alone must not train admins to force every decision.
      -- A plan edit stands for the fee it changes: compared as the fee.
      -- The plans themselves must be the ones the admin was shown.
      v_conflict:=(v_report.base_spot is not null and exists(
          select 1 from jsonb_object_keys(v_patch) k
          cross join lateral (select case when k in ('fee_plans','fee_plan') then 'fee' else k end f) m
          where case when m.f in ('parking_zones','parking_segments') then
            -- Zones and segments by id (#188): only the entries the patch
            -- names count; a report whose snapshot lacks the list falls back
            -- to the version it was made on.
            case when v_report.base_spot ? m.f
              then public.entries_patch_conflict(v_report.base_spot->m.f,v_before->m.f,v_patch->m.f)
              else v_report.base_updated_at is distinct from (v_before->>'updated_at')::timestamptz end
          else (case when m.f='facility_types' and not (v_report.base_spot ? 'facility_types')
            -- A report from before the set existed: its one type as the set.
            then case when v_report.base_spot->>'facility_type' is null then 'null'::jsonb
              else jsonb_build_array(v_report.base_spot->>'facility_type') end
            else v_report.base_spot->m.f end) is distinct from (v_before->m.f) end))
        or (v_seen is not null and (v_seen->'plans') is distinct from (v_before->'fee_plans'));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
      end if;
      -- A zone or segment patch names entries by id (#188): applied to the
      -- current list, so entries it leaves alone stay as they are.
      foreach v_list in array array['parking_zones','parking_segments'] loop
        continue when not v_patch ? v_list;
        v_merged:=public.entries_patch(v_before->v_list,v_patch->v_list);
        if v_merged is null then
          raise exception '% names an entry the spot does not have',v_list using errcode='22023';
        end if;
        -- Each zone the patch adds or changes states both vehicles (#201).
        if v_list='parking_zones' and not public.zone_patch_stated(v_patch->v_list,v_merged) then
          raise exception 'a zone this patch changes needs both vehicles stated' using errcode='22023';
        end if;
        v_patch:=jsonb_set(v_patch,array[v_list],v_merged);
      end loop;
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,parking_zones,parking_segments,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.condition,r.fee_plans,r.fee_plan,r.closure,r.parking_zones,r.parking_segments,r.status,now()
          from jsonb_populate_record(c,v_patch) r)
        where c.id=v_target returning to_jsonb(c)-'user_id'-'location' into v_after;
      -- Restoring a hidden spot supersedes the "gone" votes that hid it;
      -- otherwise the next vote recounts them and hides it again.
      if v_before->>'status'='hidden' and v_after->>'status'<>'hidden' then
        delete from spot_votes where spot_id=v_target and vote='gone';
      end if;
    else
      select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_target for update;
      if v_before is null then raise exception 'spot not found' using errcode='22023'; end if;
      -- Only the fields this patch writes count: votes or other edits that
      -- leave them alone must not train admins to force every decision.
      -- A plan edit stands for the fee it changes: compared as the fee.
      -- The plans themselves must be the ones the admin was shown.
      v_conflict:=(v_report.base_spot is not null and exists(
          select 1 from jsonb_object_keys(v_patch) k
          cross join lateral (select case when k in ('fee_plans','fee_plan') then 'fee' else k end f) m
          where case when m.f in ('parking_zones','parking_segments') then
            -- Zones and segments by id (#188): only the entries the patch
            -- names count; a report whose snapshot lacks the list falls back
            -- to the version it was made on.
            case when v_report.base_spot ? m.f
              then public.entries_patch_conflict(v_report.base_spot->m.f,v_before->m.f,v_patch->m.f)
              else v_report.base_updated_at is distinct from (v_before->>'updated_at')::timestamptz end
          else (case when m.f='facility_types' and not (v_report.base_spot ? 'facility_types')
            -- A report from before the set existed: its one type as the set.
            then case when v_report.base_spot->>'facility_type' is null then 'null'::jsonb
              else jsonb_build_array(v_report.base_spot->>'facility_type') end
            else v_report.base_spot->m.f end) is distinct from (v_before->m.f) end))
        or (v_seen is not null and (v_seen->'plans') is distinct from (v_before->'fee_plans'));
      if v_conflict and not coalesce(p_force,false) then
        raise exception 'spot changed since the report' using errcode='40001',
          hint='Review the current values, then apply again with p_force.';
      end if;
      if (v_patch ? 'fee' or v_patch ? 'fee_note') and not public.fee_note_matches(v_before||v_patch) then
        raise exception 'fee_note must be the text of fee' using errcode='22023';
      end if;
      -- A zone or segment patch names entries by id (#188): applied to the
      -- current list, so entries it leaves alone stay as they are.
      foreach v_list in array array['parking_zones','parking_segments'] loop
        continue when not v_patch ? v_list;
        v_merged:=public.entries_patch(v_before->v_list,v_patch->v_list);
        if v_merged is null then
          raise exception '% names an entry the spot does not have',v_list using errcode='22023';
        end if;
        -- Each zone the patch adds or changes states both vehicles (#201).
        if v_list='parking_zones' and not public.zone_patch_stated(v_patch->v_list,v_merged) then
          raise exception 'a zone this patch changes needs both vehicles stated' using errcode='22023';
        end if;
        v_patch:=jsonb_set(v_patch,array[v_list],v_merged);
      end loop;
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,parking_zones,parking_segments,hidden,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,coalesce(r.scooter_not_stated,false),coalesce(r.heavy_not_stated,false),
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.fee,r.condition,r.fee_plans,r.fee_plan,r.closure,r.parking_zones,r.parking_segments,r.hidden,now()
          from jsonb_populate_record(o,v_patch) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    end if;
  end if;

  perform set_config('app.admin_vehicle_fields','',true);
  update moderation_queue set status=p_decision,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note,
    resolution_kind=v_kind
    where id=p_id;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'resolve_report','moderation_queue',p_id::text,
    jsonb_build_object('report',to_jsonb(v_report),'spot',v_before),
    jsonb_build_object('status',p_decision,'resolution_kind',v_kind,'spot_table',v_table,'spot',v_after,'forced',v_conflict),
    v_note);
  return jsonb_build_object('id',p_id,'status',p_decision,'resolution_kind',v_kind,'spot',v_after);
end;
$function$;

CREATE OR REPLACE FUNCTION public.apply_report(p_user uuid, p_ip text, p_device text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$;

-- ---- Imports: an official file that leaves a vehicle out says not_stated.

CREATE OR REPLACE FUNCTION public.admin_import_fields()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['name','lat','lng','city','district','space_type','fee_note','note','heavy_allowed','scooter_allowed','heavy_not_stated','scooter_not_stated',
    'source_url','source_name','source_id','license_note','scooter_total','facility_type','facility_types','parking_access','address',
    'road_segment','entrance_note','parking_guide','special_rules','parking_zones','fee'];
$function$;

create or replace function public.admin_import_row(p_spot jsonb,p_official boolean) returns jsonb
language plpgsql stable set search_path=public,pg_temp as $$
declare
  v_fields text[]:=public.admin_import_fields();
  v_text text[]:=array['name','city','district','space_type','fee_note','note','source_url','source_name','license_note',
    'address','road_segment','entrance_note','parking_guide','special_rules'];
  v_input jsonb:='{}'; v_row jsonb; k text;
begin
  foreach k in array v_fields loop
    v_input:=v_input||jsonb_build_object(k,case
      when jsonb_typeof(p_spot->k) is distinct from 'null' and p_spot ? k then p_spot->k
      when k=any(v_text) then to_jsonb(case k when 'fee_note' then '請依現場公告' else '' end)
      when k='parking_zones' then '[]'::jsonb
      else 'null'::jsonb end);
  end loop;
  -- Eligibility (#201): an official file states a vehicle or leaves it to
  -- 官方未標示; a community file's vehicle it leaves out stays unconfirmed.
  v_input:=v_input||jsonb_build_object(
    'scooter_not_stated',p_official and jsonb_typeof(v_input->'scooter_allowed') is distinct from 'boolean',
    'heavy_not_stated',p_official and jsonb_typeof(v_input->'heavy_allowed') is distinct from 'boolean');
  -- Round-trip through the table's row type, so values compare exactly as
  -- the stored row's to_jsonb does (25.05 vs 25.050, "1" vs 1).
  if p_official then
    select to_jsonb(r) into v_row from jsonb_populate_record(null::official_heavy_spots,v_input) r;
  else
    select to_jsonb(r) into v_row from jsonb_populate_record(null::community_spots,v_input) r;
  end if;
  return (select jsonb_object_agg(f,v_row->f) from unnest(v_fields) f where v_row ? f);
end;
$$;

-- The fields an import keeps or replaces together: a fee and its text,
-- and each vehicle's flag with its not_stated; null for the others.
create function public.admin_import_pair(p_field text) returns text
language sql immutable set search_path='' as $$
  select case when p_field in ('fee','fee_note') then 'fee'
    when p_field in ('scooter_allowed','scooter_not_stated') then 'scooter'
    when p_field in ('heavy_allowed','heavy_not_stated') then 'heavy' end;
$$;

-- 202610270130_facility_types.sql's plan, pairing a vehicle's two fields.
CREATE OR REPLACE FUNCTION public.admin_import_plan(p_spots jsonb)
 RETURNS TABLE(source_id text, kind text, target uuid, status text, reason text, name text, city text, district text, base_updated_at timestamp with time zone, hidden boolean, incoming jsonb, changes jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_spot jsonb; v_index integer:=0; v_seen text[]:='{}';
  v_official boolean; v_raw text; v_current jsonb; v_owned jsonb; k text;
  v_change jsonb;
begin
  for v_spot in select value from jsonb_array_elements(p_spots) loop
    v_index:=v_index+1;
    source_id:=coalesce(v_spot->>'id',''); kind:=null; target:=null; status:=null; reason:='';
    name:=coalesce(v_spot->>'name',''); city:=coalesce(v_spot->>'city',''); district:=coalesce(v_spot->>'district','');
    base_updated_at:=null; hidden:=false; incoming:=null; changes:='[]';
    v_official:=source_id like 'official:%';
    kind:=case when v_official then 'official' else 'community' end;
    v_raw:=case when v_official then substr(source_id,10) else source_id end;
    if jsonb_typeof(v_spot) is distinct from 'object' or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      status:='invalid'; reason:=format('第 %s 筆沒有可辨識的 id',v_index); return next; continue;
    end if;
    target:=v_raw::uuid;
    if source_id=any(v_seen) then
      status:='invalid'; reason:='檔案中重複的 id'; return next; continue;
    end if;
    v_seen:=v_seen||source_id;
    if coalesce(v_spot->>'source','')<>(case when v_official then 'official' else 'import' end) then
      status:='invalid'; reason:='來源與 id 不符（官方點 id 以 official: 開頭，社群點 source 為 import）'; return next; continue;
    end if;
    begin
      incoming:=public.admin_import_row(v_spot,v_official);
    exception when others then
      status:='invalid'; reason:='欄位型別錯誤：'||sqlerrm; return next; continue;
    end;
    if btrim(coalesce(incoming->>'name',''))='' or char_length(incoming->>'name')>100 then
      reason:='名稱需為 1–100 字';
    elsif (incoming->>'lat') is null or (incoming->>'lng') is null
       or (incoming->>'lat')::float8 not between 20 and 27 or (incoming->>'lng')::float8 not between 118 and 123 then
      reason:='座標不在台灣範圍內';
    elsif btrim(coalesce(incoming->>'city',''))='' then
      reason:='缺少縣市';
    elsif v_official and (coalesce(incoming->>'source_url','') !~ '^https://' or btrim(coalesce(incoming->>'source_name',''))='') then
      reason:='官方點需要資料來源與 https 官方資料網址';
    elsif jsonb_typeof(incoming->'fee')='object' and not public.valid_fee(incoming->'fee') then
      reason:='費率格式不符';
    end if;
    if reason<>'' then status:='invalid'; return next; continue; end if;

    if not v_official then
      select to_jsonb(c)-'location' into v_current from community_spots c where c.id=target;
      if v_current is null then status:='new';
      else
        status:='existing'; reason:='社群點已存在，匯入不更新';
        base_updated_at:=(v_current->>'updated_at')::timestamptz;
        hidden:=v_current->>'status'='hidden';
      end if;
      return next; continue;
    end if;

    select to_jsonb(o) into v_current from official_heavy_spots o where o.id=target;
    if v_current is null then status:='new'; return next; continue; end if;
    -- Zones as files write them: a plan reference is the database's own
    -- (fee_plans_sync() puts it back on write), so it is no change.
    v_current:=jsonb_set(v_current,'{parking_zones}',public.zones_without_plans(v_current->'parking_zones'));
    base_updated_at:=(v_current->>'updated_at')::timestamptz;
    hidden:=(v_current->>'hidden')::boolean;
    -- A file without a fee leaves the stored one while the note it
    -- describes stays the same.
    if incoming->'fee'='null'::jsonb and incoming->'fee_note'=v_current->'fee_note' then
      incoming:=jsonb_set(incoming,'{fee}',v_current->'fee');
    end if;
    -- A note that is the stored fee's source text, beside no fee or the
    -- stored fee, describes the same fee: the stored fee and its sentence
    -- stay (202610270022 moved such notes to fee_source_text). The source
    -- text always describes the stored fee: spot_fee_source_text() clears
    -- it whenever the fee changes without one.
    if v_current->>'fee_source_text'<>'' and incoming->>'fee_note'=v_current->>'fee_source_text'
       and (incoming->'fee'='null'::jsonb or incoming->'fee'=v_current->'fee') then
      incoming:=jsonb_set(jsonb_set(incoming,'{fee}',v_current->'fee'),'{fee_note}',v_current->'fee_note');
    end if;

    -- Files written before the set (decision 58) carry facility_type alone:
    -- the stored set stays while the type is the stored first one, else
    -- the file's type becomes the set. A file with the set gives its first
    -- as facility_type, as the table keeps it.
    if incoming->'facility_types'='null'::jsonb then
      incoming:=jsonb_set(incoming,'{facility_types}',case
        when incoming->'facility_type'='null'::jsonb then 'null'::jsonb
        when incoming->'facility_type'=v_current->'facility_type'
          then coalesce(v_current->'facility_types','null'::jsonb)
        else jsonb_build_array(incoming->'facility_type') end);
    elsif jsonb_typeof(incoming->'facility_types')='array'
        and public.valid_facility_types(array(select jsonb_array_elements_text(incoming->'facility_types'))) then
      incoming:=jsonb_set(jsonb_set(incoming,'{facility_types}',to_jsonb(public.facility_types_ordered(
          array(select jsonb_array_elements_text(incoming->'facility_types'))))),
        '{facility_type}',to_jsonb(public.facility_types_ordered(
          array(select jsonb_array_elements_text(incoming->'facility_types'))))->0);
    end if;

    -- For each field, the latest audited write that changed it, if that
    -- was an administrator's and the row still holds its value.
    with entries as (
      select a.created_at,a.action,a.before as old_row,a.after as new_row
      from admin_audit_log a
      where a.target_table='official_heavy_spots' and a.target_id=target::text
        and a.action in ('create_spot','update_spot','import_spot','convert_fee')
      union all
      select a.created_at,a.action,a.before->'spot',a.after->'spot' from admin_audit_log a
      where a.action='resolve_report' and a.after->'spot'->>'id'=target::text
        and a.after->>'spot_table'='official_heavy_spots' and a.after->>'status'='accepted'
      union all
      select a.created_at,a.action,null,a.after->'official' from admin_audit_log a
      where a.action='promote_spot' and a.after->'official'->>'id'=target::text
    ),
    writes as (
      select distinct on (f) f,e.action,e.created_at,e.new_row->f as value
      from entries e cross join unnest(public.admin_import_fields()) f
      where e.new_row ? f and (e.old_row is null or (e.old_row->f) is distinct from (e.new_row->f))
      order by f,e.created_at desc
    )
    select coalesce(jsonb_object_agg(w.f,jsonb_build_object('at',w.created_at,'action',w.action)),'{}')
      into v_owned from writes w
      -- Stored zones are compared without plan references, the audited
      -- values too, so a promoted or edited zone stays the administrator's.
      where w.action<>'import_spot' and (case when w.f='parking_zones' then public.zones_without_plans(w.value)
        else w.value end) is not distinct from v_current->w.f;

    foreach k in array public.admin_import_fields() loop
      if (incoming->k) is distinct from (v_current->k) then
        v_change:=jsonb_build_object('field',k,'current',v_current->k,'incoming',incoming->k,'admin',v_owned->k);
        changes:=changes||jsonb_build_array(v_change);
      end if;
    end loop;
    -- A fee is read from its text: when either is the administrator's, both
    -- are kept or replaced together, never a file fee beside a kept text.
    -- So are a vehicle's flag and its not_stated (#201): the table clears
    -- one whenever the other is written.
    select coalesce(jsonb_agg(case
        when public.admin_import_pair(c->>'field') is not null and jsonb_typeof(c->'admin') is distinct from 'object'
        then c||jsonb_build_object('admin',(select p->'admin' from jsonb_array_elements(changes) p
          where public.admin_import_pair(p->>'field')=public.admin_import_pair(c->>'field')
            and jsonb_typeof(p->'admin')='object' limit 1))
        else c end order by o),'[]')
      into changes from jsonb_array_elements(changes) with ordinality as e(c,o);
    status:=case when changes='[]'::jsonb then 'unchanged'
      when exists(select 1 from jsonb_array_elements(changes) c where jsonb_typeof(c->'admin')='object') then 'conflict'
      else 'update' end;
    return next;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_import_apply(p_spots jsonb, p_choices jsonb, p_effective_date date, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_note text:=coalesce(p_note,'');
  v_plan record; v_choice jsonb; v_overwrite text[]; v_patch jsonb; v_kept text[];
  v_before jsonb; v_after jsonb; v_owner uuid;
  v_inserted integer:=0; v_updated integer:=0; v_skipped jsonb:='[]';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if jsonb_typeof(p_spots) is distinct from 'array' or jsonb_array_length(p_spots)>500
     or jsonb_typeof(p_choices) is distinct from 'object' or char_length(v_note)>500 then
    raise exception 'invalid import' using errcode='22023';
  end if;
  -- New community spots join the earlier imports' owner, so they read as
  -- imported rather than as the administrator's own reports.
  select c.user_id into v_owner from community_spots c where c.source='import'
    group by c.user_id order by count(*) desc limit 1;
  v_owner:=coalesce(v_owner,auth.uid());
  -- The verification trigger must not take an import for an administrator
  -- checking vehicle access on site.
  perform set_config('app.import_write','on',true);
  -- Lock what the file touches before planning, so the plan stays true.
  perform 1 from official_heavy_spots o where o.id in (
    select substr(e->>'id',10)::uuid from jsonb_array_elements(p_spots) e
    where e->>'id' ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') for update;

  for v_plan in select * from public.admin_import_plan(p_spots) p where p_choices ? p.source_id loop
    v_choice:=p_choices->v_plan.source_id;
    if v_plan.status in ('invalid','unchanged','existing') then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason',
        case v_plan.status when 'invalid' then v_plan.reason when 'unchanged' then '沒有變更' else v_plan.reason end);
      continue;
    end if;
    -- The preview showed this version; anything else was written since.
    if (case when v_plan.status='new' then v_choice->>'base_updated_at' is not null
         else v_choice->>'base_updated_at' is null
           or (v_choice->>'base_updated_at')::timestamptz is distinct from v_plan.base_updated_at end) then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason','試算後點位已變更，請重新試算');
      continue;
    end if;
    begin
      if v_plan.status='new' then
        if v_plan.kind='official' then
          if p_effective_date is null then raise exception '新增官方點需要生效日期'; end if;
          insert into official_heavy_spots(id,name,lat,lng,city,district,space_type,fee_note,note,heavy_allowed,scooter_allowed,heavy_not_stated,scooter_not_stated,
              source_url,source_name,source_id,license_note,scooter_total,facility_type,facility_types,parking_access,address,road_segment,
              entrance_note,parking_guide,special_rules,parking_zones,fee,effective_date,fee_source_text)
            select v_plan.target,r.name,r.lat,r.lng,r.city,r.district,coalesce(r.space_type,'heavyOnly'),r.fee_note,r.note,r.heavy_allowed,
              r.scooter_allowed,coalesce(r.heavy_not_stated,false),coalesce(r.scooter_not_stated,false),r.source_url,r.source_name,r.source_id,r.license_note,r.scooter_total,r.facility_type,r.facility_types,r.parking_access,
              r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.parking_zones,r.fee,p_effective_date,
              r.fee_source_text
            from jsonb_populate_record(null::official_heavy_spots,v_plan.incoming||public.fee_source_split(v_plan.incoming)) r
            returning to_jsonb(official_heavy_spots.*) into v_after;
        else
          insert into community_spots(id,user_id,source,status,name,lat,lng,city,district,space_type,fee_note,note,heavy_allowed,
              scooter_allowed,heavy_not_stated,scooter_not_stated,source_url,source_name,license_note,scooter_total,facility_type,facility_types,parking_access,address,road_segment,
              entrance_note,parking_guide,special_rules,parking_zones,fee,fee_source_text)
            select v_plan.target,v_owner,'import','pending',r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
              r.heavy_allowed,r.scooter_allowed,coalesce(r.heavy_not_stated,false),coalesce(r.scooter_not_stated,false),r.source_url,r.source_name,r.license_note,r.scooter_total,r.facility_type,r.facility_types,
              r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.parking_zones,r.fee,
              r.fee_source_text
            from jsonb_populate_record(null::community_spots,v_plan.incoming||public.fee_source_split(v_plan.incoming)) r
            returning to_jsonb(community_spots.*)-'location'-'user_id' into v_after;
        end if;
        v_inserted:=v_inserted+1;
        insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
        values(auth.uid(),'import_spot',case when v_plan.kind='official' then 'official_heavy_spots' else 'community_spots' end,
          v_plan.target::text,null,v_after,v_note);
      else
        v_overwrite:=array(select jsonb_array_elements_text(coalesce(v_choice->'overwrite','[]')));
        -- The fee and its text go together, whichever one was named.
        if v_overwrite && array['fee','fee_note'] then
          v_overwrite:=v_overwrite||array['fee','fee_note'];
        end if;
        -- A vehicle's flag and its not_stated go together too (#201): the
        -- table clears one when the other is written.
        if v_overwrite && array['scooter_allowed','scooter_not_stated'] then
          v_overwrite:=v_overwrite||array['scooter_allowed','scooter_not_stated'];
        end if;
        if v_overwrite && array['heavy_allowed','heavy_not_stated'] then
          v_overwrite:=v_overwrite||array['heavy_allowed','heavy_not_stated'];
        end if;
        select coalesce(jsonb_object_agg(c->>'field',c->'incoming'),'{}'),
               '{}'::text[]
          into v_patch,v_kept
          from jsonb_array_elements(v_plan.changes) c
          where jsonb_typeof(c->'admin') is distinct from 'object' or (c->>'field')=any(v_overwrite);
        v_kept:=array(select c->>'field' from jsonb_array_elements(v_plan.changes) c
          where jsonb_typeof(c->'admin')='object' and not (c->>'field')=any(v_overwrite));
        if v_patch='{}'::jsonb then
          v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason','保留管理員的修改，沒有其他變更');
          continue;
        end if;
        select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_plan.target;
        -- The file's note is the source text of the fee it brings.
        if v_patch ? 'fee' or v_patch ? 'fee_note' then
          v_patch:=v_patch||public.fee_source_split(v_before||v_patch);
        end if;
        update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,heavy_allowed,scooter_allowed,heavy_not_stated,scooter_not_stated,
            source_url,source_name,source_id,license_note,scooter_total,facility_type,facility_types,parking_access,address,road_segment,
            entrance_note,parking_guide,special_rules,parking_zones,fee,fee_source_text,updated_at)
          =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.heavy_allowed,r.scooter_allowed,coalesce(r.heavy_not_stated,false),coalesce(r.scooter_not_stated,false),
            r.source_url,r.source_name,r.source_id,r.license_note,r.scooter_total,r.facility_type,r.facility_types,r.parking_access,r.address,
            r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.parking_zones,r.fee,r.fee_source_text,now()
            from jsonb_populate_record(o,v_patch) r)
          where o.id=v_plan.target returning to_jsonb(o) into v_after;
        v_updated:=v_updated+1;
        insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
        values(auth.uid(),'import_spot','official_heavy_spots',v_plan.target::text,v_before,
          v_after||jsonb_build_object('import',jsonb_build_object('kept',to_jsonb(v_kept),
            'overwritten',(select coalesce(jsonb_agg(f),'[]') from unnest(v_overwrite) f where v_patch ? f))),v_note);
      end if;
    exception when others then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason','資料表拒絕：'||sqlerrm);
    end;
  end loop;
  return jsonb_build_object('inserted',v_inserted,'updated',v_updated,'skipped',v_skipped);
end;
$function$;

-- ---- History and reads carry the two columns.

CREATE OR REPLACE FUNCTION public.spot_history_fields()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','facility_types','parking_access','parking_zones','parking_segments','zones_complete','scooter_allowed','heavy_allowed','scooter_not_stated','heavy_not_stated',
    'scooter_verified_at','heavy_verified_at','fee','fee_note','fee_plan','fee_plans','fee_source_text',
    'scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note','closure','status','hidden',
    'source_name','source_url','effective_date','license_note','contributor_name'];
$function$;

CREATE OR REPLACE FUNCTION public.spot_history_public_fields()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','facility_types','parking_access','parking_zones','parking_segments','zones_complete','scooter_allowed','heavy_allowed','scooter_not_stated','heavy_not_stated',
    'fee','fee_note','scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note','closure',
    'source_name','source_url','effective_date','license_note'];
$function$;

-- 202610310010_zone_segment_ids.sql's view plus the two columns (appended).
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at,
    condition,zones_complete,closure,public.closure_state(closure) as closure_state,facility_types,parking_segments,
    scooter_not_stated,heavy_not_stated
  from public.community_spots;

-- 202610310010_zone_segment_ids.sql's official v3 plus the two columns.
drop function public.official_viewport_spots_v3(double precision,double precision,double precision,double precision);

create function public.official_viewport_spots_v3(south double precision,west double precision,north double precision,east double precision)
returns table(id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,city text,district text,space_type text,fee_note text,note text,heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamp with time zone,facility_type text,parking_access text,address text,road_segment text,scooter_total integer,entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb,contributor_name text,contributor_role text,condition jsonb,zones_complete boolean,closure jsonb,closure_state text,facility_types text[],parking_segments jsonb,scooter_not_stated boolean,heavy_not_stated boolean)
language sql stable set search_path to 'public' as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee,
    ''::text,'admin'::text,o.condition,o.zones_complete,o.closure,public.closure_state(o.closure),o.facility_types,
    o.parking_segments,o.scooter_not_stated,o.heavy_not_stated
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id limit 501;
$$;

grant execute on function public.official_viewport_spots_v3(double precision,double precision,double precision,double precision) to anon,authenticated;
