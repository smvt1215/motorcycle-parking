-- 分區與路段的穩定 id、路邊分段、格位 7 類（#188 第 1 層，設計稿 Ver.143）。
--
-- 1. parking_contract() gains zone.id_pattern, segment and bay_kinds
--    (supabase/functions/_shared/parking_contract.json). The section
--    "分區與路段" of supabase/contract/parking_contract.sql is copied below:
--    valid_zones() now also checks each zone's optional id (zone.id_pattern,
--    unique in the list) and evidence_url (https, as a basis source_url);
--    valid_segments() checks a street spot's segments; condition_bay_kind()
--    reads a condition as one of the seven bay kinds.
-- 2. Both spot tables get parking_segments (jsonb array, default []): a
--    street spot's segments, each {id, name, side?, range?, condition?,
--    total?, guide?, evidence_url?}.
-- 3. Every zone and segment carries a stable id. A trigger gives one to each
--    entry written without it: the id of the old entry with the same name
--    (zones: and area; segments: and side) when exactly one is free, else a
--    new one. Writers that know ids send them back, so renaming keeps the
--    id; writers that do not (old builds, imports) keep them by name.
--    Existing zones get ids here, without moving updated_at or the data
--    version. The tables then require an id on every entry.
-- 4. Suggestions may change zones and segments (#188): a rider's
--    proposed.parking_zones / parking_segments is a list of patches, each
--    {id, …changed keys} (null clears a key), {id, removed: true}, or a new
--    entry without an id. admin_resolve_report applies them to the current
--    list by id (entries_patch()); a conflict is an entry the patch names
--    that changed since the report (the report's snapshot keeps the lists
--    it patches), or, when the snapshot lacks them, a new version since
--    base_updated_at. apply_report stores new spots' segments.
-- 5. Imports compare zones without their ids (zones_without_plans()), so a
--    stored id is no change; the trigger keeps them on apply.
-- 6. Writers (admin upsert/promote/resolve, apply_report), the history,
--    public_spots and official_viewport_spots_v3 carry parking_segments.

-- parking_contract() as tool/gen_contract_sql.py writes it.
create or replace function public.parking_contract() returns jsonb
language sql immutable set search_path='' as $contract$
  select $json${"version":1,"space_types":["paidMotorcycle","freeMotorcycle","heavyOnly","car","offStreet","disabledMotorcycle","timedMotorcycle","flexShared","evMotorcycle"],"access_kinds":["scooterOnly","scooterHeavy","heavyCar","noMotorcycle","heavyOnly"],"placement":{"off_street_space_types":["offStreet"],"off_street_facility_types":["multiStorey","underground","surface"],"facility_types":["multiStorey","underground","surface","roadside"]},"time":{"pattern":"^([01][0-9]|2[0-3]):[0-5][0-9]$","days":["all","weekday","holiday"],"weekdays":["mon","tue","wed","thu","fri","sat","sun"],"optional_pair":["from","to"]},"date":{"pattern":"^(19|[2-9][0-9])[0-9]{2}-[0-9]{2}-[0-9]{2}$"},"condition":{"keys":["bay","use","share","charge","limits","schedule","basis"],"zone_keys":["allow"],"bay":["motorcycle","heavy","car"],"use":["usual","share"],"share":{"scooter_heavy":"motorcycle","car_motorcycle":"car"},"charge":["toll","free"],"limits":{"time_limit":{"required":[],"optional":{"max_minutes":{"min":1,"max":1440}}},"special_vehicle":{"required":["vehicle"],"optional":{}},"ev_only":{"required":[],"optional":{}}},"special_vehicles":["disabled_modified"],"street_charge_optional_with":["time_limit","special_vehicle","ev_only"],"allow_keys":["scooter","heavy"],"schedule":{"keys":["days","from","to","vehicles"],"max_entries":8,"vehicles":["scooter","heavy","car"]},"basis":{"keys":["source_url","evidence_id","effective_date","expires_on"],"required_one_of":["source_url","evidence_id"],"reserved":["evidence_id"],"source_url":{"pattern":"^https://\\S+$","max_length":2048,"length_unit":"utf16"}}},"zone":{"area":["motorcycle","car","heavy","mixed"],"id_pattern":"^[a-z0-9_-]{1,32}$"},"segment":{"keys":["id","name","side","range","condition","total","guide","evidence_url"],"max_entries":30,"sides":["east","west","south","north","both"],"name_max_length":40,"range_max_length":100,"guide_max_length":500,"total":{"min":1,"max":9999}},"bay_kinds":{"order":["motorcycle","scooter_heavy","heavy","car_motorcycle","car","disabled","ev"],"rules":[{"when":{"limit":"special_vehicle"},"bay_kind":"disabled"},{"when":{"limit":"ev_only"},"bay_kind":"ev"},{"when":{"share":"car_motorcycle"},"bay_kind":"car_motorcycle"},{"when":{"share":"scooter_heavy"},"bay_kind":"scooter_heavy"},{"when":{"bay":"heavy"},"bay_kind":"heavy"},{"when":{"bay":"car"},"bay_kind":"car"},{"when":{"bay":"motorcycle"},"bay_kind":"motorcycle"}]},"conversion":{"from_space_type":{"paidMotorcycle":{"bay":"motorcycle","use":"usual","charge":"toll"},"freeMotorcycle":{"bay":"motorcycle","use":"usual","charge":"free"},"heavyOnly":{"bay":"heavy","use":"usual"},"car":{"bay":"car","use":"usual"},"offStreet":null,"disabledMotorcycle":{"bay":"motorcycle","limits":[{"kind":"special_vehicle","vehicle":"disabled_modified"}]},"timedMotorcycle":{"bay":"motorcycle","use":"usual","limits":[{"kind":"time_limit"}]},"flexShared":{"bay":"car","use":"share","share":"car_motorcycle"},"evMotorcycle":{"bay":"motorcycle","limits":[{"kind":"ev_only"}]}},"from_access":{"scooterOnly":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}},"scooterHeavy":{"bay":"motorcycle","use":"share","share":"scooter_heavy","allow":{"scooter":true,"heavy":true}},"heavyCar":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}},"heavyOnly":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}},"noMotorcycle":{"allow":{"scooter":false,"heavy":false}}},"to_space_type":[{"when":{"placement":"off_street"},"space_type":"offStreet"},{"when":{"limit":"special_vehicle"},"space_type":"disabledMotorcycle"},{"when":{"limit":"ev_only"},"space_type":"evMotorcycle"},{"when":{"share":"car_motorcycle"},"space_type":"flexShared"},{"when":{"limit":"time_limit"},"space_type":"timedMotorcycle"},{"when":{"bay":"heavy"},"space_type":"heavyOnly"},{"when":{"bay":"car"},"space_type":"car"},{"when":{"bay":"motorcycle","charge":"toll"},"space_type":"paidMotorcycle"},{"when":{"bay":"motorcycle","charge":"free"},"space_type":"freeMotorcycle"}],"to_access":"allow 與 from_access 的 allow 相同，且 from_access 有 bay 時 bay 也相同","legacy_safe":{"unsafe_keys":["schedule"],"unsafe_basis_keys":["expires_on"],"lossy_share":"scooter_heavy","lossy_limit_keys":["max_minutes"],"assumed_charge":{"timedMotorcycle":"toll"},"lossy_when_unconfirmed":["bay","use","share","charge"]}},"fee":{"max_bytes":8192,"vehicles":["scooter","heavy","car"],"follow":{"vehicles":["heavy"],"modes":["same_as_scooter","same_as_car"],"optional":{"factor_pct":{"min":100,"max":1000}}},"modes":{"free":{"required":{},"optional":{}},"posted":{"required":{},"optional":{}},"hourly":{"required":{"amount":{"min":0,"max":10000},"per_minutes":{"min":1,"max":1440}},"optional":{"unit_minutes":{"min":1,"max":"per_minutes"},"free_minutes":{"min":1,"max":1440},"daily_cap":{"min":0,"max":10000},"cap_reset":"cap_reset"}},"per_visit":{"required":{"amount":{"min":0,"max":10000}},"optional":{"max_minutes":{"min":1,"max":1440},"renew":"renew","extension":"extension"}},"daily":{"required":{"amount":{"min":0,"max":10000}},"optional":{"cap_reset":"cap_reset"}},"by_time":{"required":{"periods":"periods"},"optional":{"cross_period":"cross_period"}}},"enums":{"cap_reset":["calendar_day","rolling_24h","per_entry"],"renew":["none","midnight"],"cross_period":["each_period","entry_only"]},"extension":{"required":{"amount":{"min":0,"max":10000},"max_times":{"min":1,"max":10}},"optional":{"minutes":{"min":1,"max":1440}}},"periods":{"max_entries":6,"keys":["days","from","to","rate"],"nested_modes":["free","posted","hourly","per_visit","daily"]}},"fee_plans":{"max_entries":12,"keys":["id","name","fee"],"id_pattern":"^[a-z0-9_-]{1,20}$","name_max_length":20}}$json$::jsonb;
$contract$;

-- ===== 分區與路段：valid_zones()、valid_segments()、condition_bay_kind()（#188） =====

-- An https link of at most max_length UTF-16 code units: the rule of a
-- basis source_url, used by a zone's or a segment's evidence_url.
create or replace function public.contract_https(p jsonb) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p)='string'
    and char_length(p#>>'{}')+regexp_count(p#>>'{}','[\U00010000-\U0010FFFF]')
      <=(public.parking_contract()->'condition'->'basis'->'source_url'->>'max_length')::integer
    and (p#>>'{}') ~ (public.parking_contract()->'condition'->'basis'->'source_url'->>'pattern'),false);
$$;

-- A string of at most p_max UTF-16 code units that is not blank.
create or replace function public.contract_text(p jsonb,p_max integer) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p)='string' and btrim(p#>>'{}')<>''
    and char_length(p#>>'{}')+regexp_count(p#>>'{}','[\U00010000-\U0010FFFF]')<=p_max,false);
$$;

-- The ids of a zone or segment list (an array): each id that is present is
-- a string of zone.id_pattern, and no two entries share one. Entries may
-- leave it out; the tables' trigger fills it in before their checks.
create or replace function public.contract_entry_ids(p jsonb) returns boolean
language sql immutable set search_path='' as $$
  select not exists(select 1 from jsonb_array_elements(p) e
      where jsonb_typeof(e)='object' and e ? 'id' and (jsonb_typeof(e->'id') is distinct from 'string'
        or (e->>'id') !~ (public.parking_contract()->'zone'->>'id_pattern')))
    and (select count(e->>'id') from jsonb_array_elements(p) e where jsonb_typeof(e)='object')
      =(select count(distinct e->>'id') from jsonb_array_elements(p) e where jsonb_typeof(e)='object');
$$;

-- A spot's parking_zones (§1.1, decision 32, #188): objects with a valid
-- fee, area and condition (whose access agrees with it), an optional https
-- evidence_url, and ids as contract_entry_ids() takes them.
create or replace function public.valid_zones(p_zones jsonb) returns boolean
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_zones) is distinct from 'array' then false else
    not exists(select 1 from jsonb_array_elements(p_zones) z
      where jsonb_typeof(z) is distinct from 'object'
        or (z ? 'fee' and not public.valid_fee(z->'fee'))
        or (z ? 'area' and not public.contract_str_in(z->'area',public.parking_contract()->'zone'->'area'))
        or (z ? 'condition' and not (public.valid_condition(z->'condition',true)
          and public.zone_condition_consistent(z)))
        or (z ? 'evidence_url' and not public.contract_https(z->'evidence_url')))
    and public.contract_entry_ids(p_zones) end;
$$;

-- A street spot's parking_segments (#188, segment): at most max_entries
-- objects of the listed keys, each named, with an optional side, range,
-- guide, number of bays, https evidence_url and a zone-style condition
-- without allow (the city's rules decide who may park).
create or replace function public.valid_segments(p_segments jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare c jsonb:=public.parking_contract()->'segment'; s jsonb;
begin
  if jsonb_typeof(p_segments) is distinct from 'array'
    or jsonb_array_length(p_segments)>(c->>'max_entries')::integer then return false; end if;
  for s in select e from jsonb_array_elements(p_segments) e loop
    if jsonb_typeof(s) is distinct from 'object'
      or exists(select 1 from jsonb_object_keys(s) k where not c->'keys' ? k)
      or not public.contract_text(s->'name',(c->>'name_max_length')::integer)
      or (s ? 'side' and not public.contract_str_in(s->'side',c->'sides'))
      or (s ? 'range' and not public.contract_text(s->'range',(c->>'range_max_length')::integer))
      or (s ? 'guide' and not public.contract_text(s->'guide',(c->>'guide_max_length')::integer))
      or (s ? 'total' and not public.contract_whole(s->'total',(c->'total'->>'min')::numeric,(c->'total'->>'max')::numeric))
      or (s ? 'condition' and not (public.valid_condition(s->'condition',true) and not s->'condition' ? 'allow'))
      or (s ? 'evidence_url' and not public.contract_https(s->'evidence_url'))
    then return false; end if;
  end loop;
  return public.contract_entry_ids(p_segments);
end;
$$;

-- The bay kind a condition reads as (#188, bay_kinds): the first rule that
-- matches, or null (unconfirmed).
create or replace function public.condition_bay_kind(p_condition jsonb) returns text
language plpgsql immutable set search_path='' as $$
declare r jsonb; w jsonb;
begin
  if jsonb_typeof(p_condition) is distinct from 'object' then return null; end if;
  for r in select e from jsonb_array_elements(public.parking_contract()->'bay_kinds'->'rules') e loop
    w:=r->'when';
    if (not w ? 'limit' or exists(select 1 from jsonb_array_elements(
        case when jsonb_typeof(p_condition->'limits')='array' then p_condition->'limits' else '[]'::jsonb end) l
        where l->>'kind'=w->>'limit'))
      and (not w ? 'share' or p_condition->>'share' is not distinct from w->>'share')
      and (not w ? 'bay' or p_condition->>'bay' is not distinct from w->>'bay')
    then return r->>'bay_kind'; end if;
  end loop;
  return null;
end;
$$;

-- Whether every object entry of a zone or segment list has an id: what the
-- tables hold once the trigger has run.
create or replace function public.entries_have_ids(p jsonb) returns boolean
language sql immutable set search_path='' as $$
  select jsonb_typeof(p)='array' and not exists(select 1 from jsonb_array_elements(p) e
    where jsonb_typeof(e)='object' and not e ? 'id');
$$;

-- p_new with an id on every object entry: an entry that has one keeps it;
-- one without takes the id of the entry of p_old that matches it on p_keys
-- when exactly one such entry exists and no entry of p_new uses its id;
-- otherwise a new random id. Unchanged when no entry lacks an id.
create or replace function public.entries_with_ids(p_new jsonb,p_old jsonb,p_keys text[]) returns jsonb
language plpgsql volatile set search_path='' as $$
declare
  v jsonb:='[]'::jsonb; e jsonb; v_id text; v_count integer;
  v_old jsonb:=case when jsonb_typeof(p_old)='array' then p_old else '[]'::jsonb end;
  v_used text[];
begin
  if jsonb_typeof(p_new) is distinct from 'array' or public.entries_have_ids(p_new) then return p_new; end if;
  v_used:=array(select x->>'id' from jsonb_array_elements(p_new) x
    where jsonb_typeof(x)='object' and jsonb_typeof(x->'id')='string');
  for e in select x from jsonb_array_elements(p_new) with ordinality t(x,n) order by n loop
    if jsonb_typeof(e)='object' and not e ? 'id' then
      select min(o->>'id'),count(*) into v_id,v_count from jsonb_array_elements(v_old) o
        where jsonb_typeof(o)='object' and jsonb_typeof(o->'id')='string' and not (o->>'id')=any(v_used)
          and not exists(select 1 from unnest(p_keys) k where (o->k) is distinct from (e->k));
      if v_count<>1 then
        loop
          v_id:=substr(replace(gen_random_uuid()::text,'-',''),1,12);
          exit when not v_id=any(v_used);
        end loop;
      end if;
      v_used:=v_used||v_id;
      e:=jsonb_build_object('id',v_id)||e;
    end if;
    v:=v||jsonb_build_array(e);
  end loop;
  return v;
end;
$$;

alter table public.community_spots add column parking_segments jsonb not null default '[]'::jsonb
  constraint community_spots_segments_check check (public.valid_segments(parking_segments));
alter table public.official_heavy_spots add column parking_segments jsonb not null default '[]'::jsonb
  constraint official_heavy_spots_segments_check check (public.valid_segments(parking_segments));

-- Last of the BEFORE triggers (alphabetical: "zone_ids" sorts after
-- "fee_plans", which rewrites zones' fees), so it sees the lists as stored.
create or replace function public.assign_entry_ids() returns trigger
language plpgsql set search_path='' as $$
begin
  new.parking_zones:=public.entries_with_ids(new.parking_zones,
    case when tg_op='UPDATE' then old.parking_zones end,array['name','area']);
  new.parking_segments:=public.entries_with_ids(new.parking_segments,
    case when tg_op='UPDATE' then old.parking_segments end,array['name','side']);
  return new;
end;
$$;

create trigger community_spots_zone_ids before insert or update on public.community_spots
  for each row execute function public.assign_entry_ids();
create trigger official_heavy_spots_zone_ids before insert or update on public.official_heavy_spots
  for each row execute function public.assign_entry_ids();

-- Existing zones get their ids. Plain updates of the column alone:
-- updated_at, the data version and the history stay as they are.
alter table public.community_spots disable trigger user;
alter table public.official_heavy_spots disable trigger user;
update public.community_spots set parking_zones=public.entries_with_ids(parking_zones,null,array['name','area'])
  where not public.entries_have_ids(parking_zones);
update public.official_heavy_spots set parking_zones=public.entries_with_ids(parking_zones,null,array['name','area'])
  where not public.entries_have_ids(parking_zones);
alter table public.community_spots enable trigger user;
alter table public.official_heavy_spots enable trigger user;

-- valid_zones() changed under the zones checks: check every row again, as
-- 202610270020 did; the id checks are new.
alter table public.community_spots drop constraint community_spots_zones_check;
alter table public.community_spots add constraint community_spots_zones_check
  check (public.valid_zones(parking_zones)) not valid;
alter table public.community_spots validate constraint community_spots_zones_check;
alter table public.official_heavy_spots drop constraint official_spots_zones_check;
alter table public.official_heavy_spots add constraint official_spots_zones_check
  check (public.valid_zones(parking_zones)) not valid;
alter table public.official_heavy_spots validate constraint official_spots_zones_check;
alter table public.community_spots add constraint community_spots_entry_ids_check
  check (public.entries_have_ids(parking_zones) and public.entries_have_ids(parking_segments));
alter table public.official_heavy_spots add constraint official_heavy_spots_entry_ids_check
  check (public.entries_have_ids(parking_zones) and public.entries_have_ids(parking_segments));

grant select (parking_segments) on public.community_spots to anon,authenticated;

-- 202610270023_fee_plans.sql's comparison copy of zones, now also without
-- their ids: an import never sends them, and a stored id is no change.
create or replace function public.zones_without_plans(p_zones jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_zones)='array'
    then coalesce((select jsonb_agg(case when jsonb_typeof(z)='object' then z-'fee_plan'-'id' else z end order by n)
      from jsonb_array_elements(p_zones) with ordinality x(z,n)),'[]'::jsonb)
    else p_zones end;
$$;

-- 202610240011_admin_review.sql's snapshot, keeping the zones or segments
-- a report proposes to change: the review compares those entries by id.
create or replace function public.moderation_base_version() returns trigger
language plpgsql set search_path='' as $$
declare
  v_drop text[]:=array['photo_urls']
    ||case when coalesce(new.proposed ? 'parking_zones',false) then '{}'::text[] else array['parking_zones'] end
    ||case when coalesce(new.proposed ? 'parking_segments',false) then '{}'::text[] else array['parking_segments'] end;
begin
  if new.base_updated_at is null then
    if new.source_id like 'official:%' and substr(new.source_id,10) ~* '^[0-9a-f-]{36}$' then
      select o.updated_at,to_jsonb(o)-v_drop into new.base_updated_at,new.base_spot
        from public.official_heavy_spots o where o.id=substr(new.source_id,10)::uuid;
    elsif new.source_id ~* '^[0-9a-f-]{36}$' then
      select c.updated_at,to_jsonb(c)-'user_id'-'location'-v_drop into new.base_updated_at,new.base_spot
        from public.community_spots c where c.id=new.source_id::uuid;
    end if;
  end if;
  return new;
end;
$$;

-- p_current (a zone or segment list) with p_patch applied: an entry with an
-- id changes the current entry with that id, its keys replacing the
-- current ones and a null value removing one (a fee sent leaves the zone's
-- plan reference; an access sent without a condition brings the condition's
-- allow, and bay, in line with it); {"id": …, "removed": true}
-- removes it; an entry without an id is added at the end. Entries the patch
-- does not name stay as they are, in place. Null when the patch is not a
-- list of objects or names an id the list does not have.
create or replace function public.entries_patch(p_current jsonb,p_patch jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare v jsonb:=coalesce(p_current,'[]'::jsonb); e jsonb; i integer; v_z jsonb; v_a jsonb; v_c jsonb;
begin
  if jsonb_typeof(v)<>'array' or jsonb_typeof(p_patch) is distinct from 'array' then return null; end if;
  for e in select x from jsonb_array_elements(p_patch) with ordinality t(x,n) order by n loop
    if jsonb_typeof(e)<>'object' then return null; end if;
    if e ? 'id' then
      i:=(select n-1 from jsonb_array_elements(v) with ordinality t(z,n)
        where jsonb_typeof(z)='object' and z->'id'=e->'id' limit 1);
      if i is null then return null; end if;
      if e ? 'removed' then
        if e->'removed'<>'true'::jsonb or e-'id'-'removed'<>'{}'::jsonb then return null; end if;
        v:=v-i;
      else
        v_z:=(select coalesce(jsonb_object_agg(k,x),'{}'::jsonb)
          from jsonb_each(v->i||e) j(k,x) where jsonb_typeof(x)<>'null');
        -- A new or cleared fee leaves the plan it copied; else the plan's
        -- fee would be copied back over it (fee_plans_sync()).
        if e ? 'fee' and not e ? 'fee_plan' then v_z:=v_z-'fee_plan'; end if;
        -- A new access without a condition carries the condition with it,
        -- so the two still agree (decision 32): the access's allow, and its
        -- bay when it names one (a shared use of another bay goes); no
        -- access left, no condition.
        if e ? 'access' and not e ? 'condition' and v_z ? 'condition' then
          v_a:=public.parking_contract()->'conversion'->'from_access'->(v_z->>'access');
          if v_a is null then
            v_z:=v_z-'condition';
          else
            v_c:=v_z->'condition'||jsonb_build_object('allow',v_a->'allow');
            if v_a ? 'bay' and (v_c->'bay') is distinct from (v_a->'bay') then
              v_c:=(v_c-'use'-'share')||jsonb_build_object('bay',v_a->'bay');
            end if;
            v_z:=jsonb_set(v_z,'{condition}',v_c);
          end if;
        end if;
        v:=jsonb_set(v,array[i::text],v_z);
      end if;
    else
      if e ? 'removed' then return null; end if;
      v:=v||jsonb_build_array((select coalesce(jsonb_object_agg(k,x),'{}'::jsonb)
        from jsonb_each(e) j(k,x) where jsonb_typeof(x)<>'null'));
    end if;
  end loop;
  return v;
end;
$$;

-- Whether an entry p_patch names by id differs between the list a report
-- saw (p_base) and the current one: changed, removed or added since.
create or replace function public.entries_patch_conflict(p_base jsonb,p_current jsonb,p_patch jsonb) returns boolean
language sql immutable set search_path='' as $$
  select exists(select 1 from jsonb_array_elements(case when jsonb_typeof(p_patch)='array' then p_patch else '[]'::jsonb end) e
    where jsonb_typeof(e)='object' and e ? 'id'
      and (select z from jsonb_array_elements(case when jsonb_typeof(p_base)='array' then p_base else '[]'::jsonb end) z
          where z->'id'=e->'id' limit 1)
        is distinct from (select z from jsonb_array_elements(case when jsonb_typeof(p_current)='array' then p_current else '[]'::jsonb end) z
          where z->'id'=e->'id' limit 1));
$$;

-- ---- Writers carry parking_segments; the review applies zone and segment
-- patches by id (#188).

CREATE OR REPLACE FUNCTION public.admin_spot_fields(p_official boolean)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['name','lat','lng','city','district','space_type','fee_note','note',
    'scooter_allowed','heavy_allowed','facility_type','facility_types','parking_access','address','road_segment',
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
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure)
        select r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),coalesce(r.note,''),
          r.scooter_allowed,r.heavy_allowed,r.facility_type,r.facility_types,r.parking_access,coalesce(r.address,''),coalesce(r.road_segment,''),
          coalesce(r.entrance_note,''),coalesce(r.parking_guide,''),coalesce(r.special_rules,''),r.scooter_total,
          r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),r.fee,
          r.condition,coalesce(r.zones_complete,false),coalesce(r.parking_zones,'[]'::jsonb),coalesce(r.parking_segments,'[]'::jsonb),r.fee_plans,r.fee_plan,r.closure
        from jsonb_populate_record(null::official_heavy_spots,v_values) r
        returning to_jsonb(official_heavy_spots.*) into v_after;
    else
      insert into community_spots(user_id,source,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure)
        select auth.uid(),'community',r.name,r.lat,r.lng,r.city,coalesce(r.district,''),r.space_type,coalesce(r.fee_note,'請依現場公告'),
          coalesce(r.note,''),r.scooter_allowed,r.heavy_allowed,r.facility_type,r.facility_types,r.parking_access,coalesce(r.address,''),
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
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,
          source_name,source_url,effective_date,license_note,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.source_name,r.source_url,r.effective_date,r.license_note,r.fee,r.condition,r.zones_complete,
          r.parking_zones,r.parking_segments,r.fee_plans,r.fee_plan,r.closure,now()
          from jsonb_populate_record(o,v_values) r)
        where o.id=v_target returning to_jsonb(o) into v_after;
    else
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,status,fee,condition,zones_complete,parking_zones,parking_segments,fee_plans,fee_plan,closure,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
          r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
          r.status,r.fee,r.condition,r.zones_complete,r.parking_zones,r.parking_segments,r.fee_plans,r.fee_plan,r.closure,now()
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
  select * into v_community from community_spots where id=p_source_id::uuid for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  if v_community.updated_at<>p_base_updated_at then
    raise exception 'spot changed since it was opened' using errcode='40001';
  end if;
  if v_community.status='hidden' then
    raise exception 'restore the spot before promoting it' using errcode='22023';
  end if;

  insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
      facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,parking_zones,parking_segments,
      source_name,source_url,effective_date,license_note,fee,condition,zones_complete,closure)
    select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
      -- Only what the admin states in this call; never the rider's values.
      case when v_values ? 'scooter_allowed' then (v_values->>'scooter_allowed')::boolean end,
      case when v_values ? 'heavy_allowed' then (v_values->>'heavy_allowed')::boolean end,
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
    'scooter_allowed','heavy_allowed','facility_type','facility_types','parking_access','address','road_segment',
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
        v_patch:=jsonb_set(v_patch,array[v_list],v_merged);
      end loop;
      update community_spots c set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,parking_zones,parking_segments,status,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
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
        v_patch:=jsonb_set(v_patch,array[v_list],v_merged);
      end loop;
      update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,
          facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,fee,condition,fee_plans,fee_plan,closure,parking_zones,parking_segments,hidden,updated_at)
        =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.scooter_allowed,r.heavy_allowed,
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
    insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,fee,
        facility_type,facility_types,parking_access,entrance_note,parking_guide,parking_zones,parking_segments,condition)
    values(p_user,btrim(v_spot->>'name'),(v_spot->>'lat')::float8,(v_spot->>'lng')::float8,v_spot->>'city',coalesce(v_spot->>'district',''),v_spot->>'space_type',coalesce(v_spot->>'fee_note','請依現場公告'),coalesce(v_spot->>'note',''),(v_spot->>'scooter_allowed')::boolean,(v_spot->>'heavy_allowed')::boolean,
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

-- The history records the segments like the zones.

CREATE OR REPLACE FUNCTION public.spot_history_fields()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['name','lat','lng','city','district','address','road_segment','space_type','condition',
    'facility_type','facility_types','parking_access','parking_zones','parking_segments','zones_complete','scooter_allowed','heavy_allowed',
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
    'facility_type','facility_types','parking_access','parking_zones','parking_segments','zones_complete','scooter_allowed','heavy_allowed',
    'fee','fee_note','scooter_total','entrance_note','parking_guide','special_rules','photo_urls','note','closure',
    'source_name','source_url','effective_date','license_note'];
$function$;

-- 202610270130_facility_types.sql's view plus parking_segments (appended: a
-- view keeps its columns in place). The viewports returning it pick it up.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at,
    condition,zones_complete,closure,public.closure_state(closure) as closure_state,facility_types,parking_segments
  from public.community_spots;

-- 202610270130_facility_types.sql's official v3 plus parking_segments; its
-- return type changes, so it is dropped and created again.
drop function public.official_viewport_spots_v3(double precision,double precision,double precision,double precision);

create function public.official_viewport_spots_v3(south double precision,west double precision,north double precision,east double precision)
returns table(id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,city text,district text,space_type text,fee_note text,note text,heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamp with time zone,facility_type text,parking_access text,address text,road_segment text,scooter_total integer,entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb,contributor_name text,contributor_role text,condition jsonb,zones_complete boolean,closure jsonb,closure_state text,facility_types text[],parking_segments jsonb)
language sql stable set search_path to 'public' as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee,
    ''::text,'admin'::text,o.condition,o.zones_complete,o.closure,public.closure_state(o.closure),o.facility_types,
    o.parking_segments
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id limit 501;
$$;

grant execute on function public.official_viewport_spots_v3(double precision,double precision,double precision,double precision) to anon,authenticated;
