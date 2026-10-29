-- 格位分類改版（決定 62、63）：加註條件「時段性禁停」。
--
-- 1. The contract gets a limit kind no_parking whose required periods name
--    when parking is banned (07:00–09:00 平日, 假日全天…): 1 to
--    limit_periods.max_entries entries of days, from and to, under the same
--    rules as a schedule slot without vehicles. parking_contract() and
--    valid_condition() are copied from supabase/contract/parking_contract.sql
--    as tool/gen_contract_sql.py writes them.
-- 2. no_parking never decides the legacy space type: a bay with it is still
--    the space type its bay, charge and other limits convert to, and is not
--    legacy-safe (old builds do not know the ban), so legacy_projection()
--    shows it to them as an unverified lot, as it does a schedule.
-- 3. 限時機車格 is no longer a kind riders pick (一般機車格＋限時), but its
--    conversion stays: a motorcycle bay with time_limit is still stored as
--    timedMotorcycle, so no existing row changes and nothing is rewritten.
-- 4. Every stored condition stays valid: the new rules only add a kind.

create or replace function public.parking_contract() returns jsonb
language sql immutable set search_path='' as $contract$
  select $json${"version":1,"space_types":["paidMotorcycle","freeMotorcycle","heavyOnly","car","offStreet","disabledMotorcycle","timedMotorcycle","flexShared","evMotorcycle"],"access_kinds":["scooterOnly","scooterHeavy","heavyCar","noMotorcycle","heavyOnly"],"placement":{"off_street_space_types":["offStreet"],"off_street_facility_types":["multiStorey","underground","surface"],"facility_types":["multiStorey","underground","surface","roadside"]},"time":{"pattern":"^([01][0-9]|2[0-3]):[0-5][0-9]$","days":["all","weekday","holiday"],"weekdays":["mon","tue","wed","thu","fri","sat","sun"],"optional_pair":["from","to"]},"date":{"pattern":"^(19|[2-9][0-9])[0-9]{2}-[0-9]{2}-[0-9]{2}$"},"condition":{"keys":["bay","use","share","charge","limits","schedule","basis"],"zone_keys":["allow"],"bay":["motorcycle","heavy","car"],"use":["usual","share"],"share":{"scooter_heavy":"motorcycle","car_motorcycle":"car"},"charge":["toll","free"],"limits":{"time_limit":{"required":[],"optional":{"max_minutes":{"min":1,"max":1440}}},"special_vehicle":{"required":["vehicle"],"optional":{}},"ev_only":{"required":[],"optional":{}},"no_parking":{"required":["periods"],"optional":{}}},"limit_periods":{"keys":["days","from","to"],"max_entries":6},"special_vehicles":["disabled_modified"],"street_charge_optional_with":["time_limit","special_vehicle","ev_only"],"allow_keys":["scooter","heavy"],"schedule":{"keys":["days","from","to","vehicles"],"max_entries":8,"vehicles":["scooter","heavy","car"]},"basis":{"keys":["source_url","evidence_id","effective_date","expires_on"],"required_one_of":["source_url","evidence_id"],"reserved":["evidence_id"],"source_url":{"pattern":"^https://\\S+$","max_length":2048,"length_unit":"utf16"}}},"zone":{"area":["motorcycle","car","heavy","mixed"]},"conversion":{"from_space_type":{"paidMotorcycle":{"bay":"motorcycle","use":"usual","charge":"toll"},"freeMotorcycle":{"bay":"motorcycle","use":"usual","charge":"free"},"heavyOnly":{"bay":"heavy","use":"usual"},"car":{"bay":"car","use":"usual"},"offStreet":null,"disabledMotorcycle":{"bay":"motorcycle","limits":[{"kind":"special_vehicle","vehicle":"disabled_modified"}]},"timedMotorcycle":{"bay":"motorcycle","use":"usual","limits":[{"kind":"time_limit"}]},"flexShared":{"bay":"car","use":"share","share":"car_motorcycle"},"evMotorcycle":{"bay":"motorcycle","limits":[{"kind":"ev_only"}]}},"from_access":{"scooterOnly":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}},"scooterHeavy":{"bay":"motorcycle","use":"share","share":"scooter_heavy","allow":{"scooter":true,"heavy":true}},"heavyCar":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}},"heavyOnly":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}},"noMotorcycle":{"allow":{"scooter":false,"heavy":false}}},"to_space_type":[{"when":{"placement":"off_street"},"space_type":"offStreet"},{"when":{"limit":"special_vehicle"},"space_type":"disabledMotorcycle"},{"when":{"limit":"ev_only"},"space_type":"evMotorcycle"},{"when":{"share":"car_motorcycle"},"space_type":"flexShared"},{"when":{"limit":"time_limit"},"space_type":"timedMotorcycle"},{"when":{"bay":"heavy"},"space_type":"heavyOnly"},{"when":{"bay":"car"},"space_type":"car"},{"when":{"bay":"motorcycle","charge":"toll"},"space_type":"paidMotorcycle"},{"when":{"bay":"motorcycle","charge":"free"},"space_type":"freeMotorcycle"}],"to_access":"allow 與 from_access 的 allow 相同，且 from_access 有 bay 時 bay 也相同","legacy_safe":{"unsafe_keys":["schedule"],"unsafe_basis_keys":["expires_on"],"lossy_share":"scooter_heavy","lossy_limit_keys":["max_minutes"],"assumed_charge":{"timedMotorcycle":"toll"},"lossy_when_unconfirmed":["bay","use","share","charge"]}},"fee":{"max_bytes":8192,"vehicles":["scooter","heavy","car"],"follow":{"vehicles":["heavy"],"modes":["same_as_scooter","same_as_car"],"optional":{"factor_pct":{"min":100,"max":1000}}},"modes":{"free":{"required":{},"optional":{}},"posted":{"required":{},"optional":{}},"hourly":{"required":{"amount":{"min":0,"max":10000},"per_minutes":{"min":1,"max":1440}},"optional":{"unit_minutes":{"min":1,"max":"per_minutes"},"free_minutes":{"min":1,"max":1440},"daily_cap":{"min":0,"max":10000},"cap_reset":"cap_reset"}},"per_visit":{"required":{"amount":{"min":0,"max":10000}},"optional":{"max_minutes":{"min":1,"max":1440},"renew":"renew","extension":"extension"}},"daily":{"required":{"amount":{"min":0,"max":10000}},"optional":{"cap_reset":"cap_reset"}},"by_time":{"required":{"periods":"periods"},"optional":{"cross_period":"cross_period"}}},"enums":{"cap_reset":["calendar_day","rolling_24h","per_entry"],"renew":["none","midnight"],"cross_period":["each_period","entry_only"]},"extension":{"required":{"amount":{"min":0,"max":10000},"max_times":{"min":1,"max":10}},"optional":{"minutes":{"min":1,"max":1440}}},"periods":{"max_entries":6,"keys":["days","from","to","rate"],"nested_modes":["free","posted","hourly","per_visit","daily"]}},"fee_plans":{"max_entries":12,"keys":["id","name","fee"],"id_pattern":"^[a-z0-9_-]{1,20}$","name_max_length":20}}$json$::jsonb;
$contract$;

-- A bay's or a zone's condition (§1.2, §4.3), the same rules as
-- validCondition in validate.ts and lib/models/parking_condition.dart; a
-- limit's periods follow limit_periods (decision 62).
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
      -- A limit's periods (時段性禁停, decision 62): like schedule slots, without vehicles.
      if l ? 'periods' then
        if jsonb_typeof(l->'periods') is distinct from 'array'
          or jsonb_array_length(l->'periods') not between 1 and (c->'limit_periods'->>'max_entries')::integer
        then return false; end if;
        if exists(select 1 from jsonb_array_elements(l->'periods') e
            where not public.contract_slot_keys(e,c->'limit_periods'->'keys') or not public.contract_slot_times(e))
        then return false; end if;
      end if;
    end loop;
  end if;
  if not p_zone and p->>'bay'='motorcycle' and not p ? 'charge'
    and not kinds && array(select jsonb_array_elements_text(c->'street_charge_optional_with'))
  then return false; end if;

  if p ? 'allow' then
    v:=p->'allow';
    if jsonb_typeof(v) is distinct from 'object' or v='{}'::jsonb
      or exists(select 1 from jsonb_each(v) e where not c->'allow_keys' ? e.key or jsonb_typeof(e.value)<>'boolean')
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
