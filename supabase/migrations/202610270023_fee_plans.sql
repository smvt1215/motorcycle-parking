-- Fee plans (docs/designs/2026-10-26-parking-conditions-and-fees.md §2.6,
-- §7 item 10; stack C, C3 second layer). A spot keeps its rates as named
-- plans, fee_plans [{id, name, fee}]; a street spot refers to one with
-- fee_plan, each zone with parking_zones[].fee_plan, so bays at one price
-- share one plan.
--
-- Builds that read only fee (every build so far, favorites included) must
-- still see the rates: a spot or zone that refers to a plan carries the
-- plan's fee as its own fee, kept in step on every write by
-- fee_plans_sync() (a trigger), and valid_fee_plans() refuses a copy that
-- differs. The original and v2 viewports, v3 and favorites therefore keep
-- returning fee and parking_zones[].fee unchanged: the plans are expanded
-- when written, not when read.
--
-- Writers that know nothing of plans (apply_report, the admin RPCs, import,
-- fee conversion) keep writing fee. fee_plans_sync() takes such a fee into
-- a plan: an existing plan with the same fee, or a new one with an id p1,
-- p2, … and a name from its vehicles and modes (機車計時); plans no longer
-- referred to are then dropped. Every existing fee becomes a plan below.

-- ===== 契約（tool/gen_contract_sql.py；parking_contract.json 加了 fee_plans） =====
create or replace function public.parking_contract() returns jsonb
language sql immutable set search_path='' as $contract$
  select $json${"version":1,"space_types":["paidMotorcycle","freeMotorcycle","heavyOnly","car","offStreet","disabledMotorcycle","timedMotorcycle","flexShared","evMotorcycle"],"access_kinds":["scooterOnly","scooterHeavy","heavyCar","noMotorcycle","heavyOnly"],"placement":{"off_street_space_types":["offStreet"],"off_street_facility_types":["multiStorey","underground","surface"]},"time":{"pattern":"^([01][0-9]|2[0-3]):[0-5][0-9]$","days":["all","weekday","holiday"],"weekdays":["mon","tue","wed","thu","fri","sat","sun"],"optional_pair":["from","to"]},"date":{"pattern":"^(19|[2-9][0-9])[0-9]{2}-[0-9]{2}-[0-9]{2}$"},"condition":{"keys":["bay","use","share","charge","limits","schedule","basis"],"zone_keys":["allow"],"bay":["motorcycle","heavy","car"],"use":["usual","share"],"share":{"scooter_heavy":"motorcycle","car_motorcycle":"car"},"charge":["toll","free"],"limits":{"time_limit":{"required":[],"optional":{"max_minutes":{"min":1,"max":1440}}},"special_vehicle":{"required":["vehicle"],"optional":{}},"ev_only":{"required":[],"optional":{}}},"special_vehicles":["disabled_modified"],"street_charge_optional_with":["time_limit","special_vehicle","ev_only"],"allow_keys":["scooter","heavy"],"schedule":{"keys":["days","from","to","vehicles"],"max_entries":8,"vehicles":["scooter","heavy","car"]},"basis":{"keys":["source_url","evidence_id","effective_date","expires_on"],"required_one_of":["source_url","evidence_id"],"reserved":["evidence_id"],"source_url":{"pattern":"^https://\\S+$","max_length":2048,"length_unit":"utf16"}}},"zone":{"area":["motorcycle","car","heavy","mixed"]},"conversion":{"from_space_type":{"paidMotorcycle":{"bay":"motorcycle","use":"usual","charge":"toll"},"freeMotorcycle":{"bay":"motorcycle","use":"usual","charge":"free"},"heavyOnly":{"bay":"heavy","use":"usual"},"car":{"bay":"car","use":"usual"},"offStreet":null,"disabledMotorcycle":{"bay":"motorcycle","limits":[{"kind":"special_vehicle","vehicle":"disabled_modified"}]},"timedMotorcycle":{"bay":"motorcycle","use":"usual","limits":[{"kind":"time_limit"}]},"flexShared":{"bay":"car","use":"share","share":"car_motorcycle"},"evMotorcycle":{"bay":"motorcycle","limits":[{"kind":"ev_only"}]}},"from_access":{"scooterOnly":{"bay":"motorcycle","use":"usual","allow":{"scooter":true,"heavy":false}},"scooterHeavy":{"bay":"motorcycle","use":"share","share":"scooter_heavy","allow":{"scooter":true,"heavy":true}},"heavyCar":{"bay":"car","use":"usual","allow":{"scooter":false,"heavy":true}},"heavyOnly":{"bay":"heavy","use":"usual","allow":{"scooter":false,"heavy":true}},"noMotorcycle":{"allow":{"scooter":false,"heavy":false}}},"to_space_type":[{"when":{"placement":"off_street"},"space_type":"offStreet"},{"when":{"limit":"special_vehicle"},"space_type":"disabledMotorcycle"},{"when":{"limit":"ev_only"},"space_type":"evMotorcycle"},{"when":{"share":"car_motorcycle"},"space_type":"flexShared"},{"when":{"limit":"time_limit"},"space_type":"timedMotorcycle"},{"when":{"bay":"heavy"},"space_type":"heavyOnly"},{"when":{"bay":"car"},"space_type":"car"},{"when":{"bay":"motorcycle","charge":"toll"},"space_type":"paidMotorcycle"},{"when":{"bay":"motorcycle","charge":"free"},"space_type":"freeMotorcycle"}],"to_access":"allow 與 from_access 的 allow 相同，且 from_access 有 bay 時 bay 也相同","legacy_safe":{"unsafe_keys":["schedule"],"unsafe_basis_keys":["expires_on"],"lossy_share":"scooter_heavy","lossy_limit_keys":["max_minutes"],"assumed_charge":{"timedMotorcycle":"toll"},"lossy_when_unconfirmed":["bay","use","share","charge"]}},"fee":{"max_bytes":8192,"vehicles":["scooter","heavy","car"],"follow":{"vehicles":["heavy"],"modes":["same_as_scooter","same_as_car"],"optional":{"factor_pct":{"min":100,"max":1000}}},"modes":{"free":{"required":{},"optional":{}},"posted":{"required":{},"optional":{}},"hourly":{"required":{"amount":{"min":0,"max":10000},"per_minutes":{"min":1,"max":1440}},"optional":{"unit_minutes":{"min":1,"max":"per_minutes"},"free_minutes":{"min":1,"max":1440},"daily_cap":{"min":0,"max":10000},"cap_reset":"cap_reset"}},"per_visit":{"required":{"amount":{"min":0,"max":10000}},"optional":{"max_minutes":{"min":1,"max":1440},"renew":"renew","extension":"extension"}},"daily":{"required":{"amount":{"min":0,"max":10000}},"optional":{"cap_reset":"cap_reset"}},"by_time":{"required":{"periods":"periods"},"optional":{"cross_period":"cross_period"}}},"enums":{"cap_reset":["calendar_day","rolling_24h","per_entry"],"renew":["none","midnight"],"cross_period":["each_period","entry_only"]},"extension":{"required":{"amount":{"min":0,"max":10000},"max_times":{"min":1,"max":10}},"optional":{"minutes":{"min":1,"max":1440}}},"periods":{"max_entries":6,"keys":["days","from","to","rate"],"nested_modes":["free","posted","hourly","per_visit","daily"]}},"fee_plans":{"max_entries":12,"keys":["id","name","fee"],"id_pattern":"^[a-z0-9_-]{1,20}$","name_max_length":20}}$json$::jsonb;
$contract$;

-- ===== 計費規則：valid_fee_plans()（C3 第二層，§2.6） =====

-- A spot's fee plans, its own plan reference and its zones' (§2.6): at
-- most max_entries plans of {id, name, fee}, ids unique and of id_pattern,
-- names of 1–name_max_length UTF-16 code units, each fee a valid, non-empty
-- fee. Every reference names an existing plan, and a spot or zone that
-- refers to one carries that plan's fee as its own copy for older builds.
create or replace function public.valid_fee_plans(p_plans jsonb,p_fee_plan text,p_fee jsonb,p_zones jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare c jsonb:=public.parking_contract()->'fee_plans'; p jsonb; z jsonb; ids text[]:='{}';
begin
  if coalesce(jsonb_typeof(p_plans),'null')<>'null' then
    if jsonb_typeof(p_plans)<>'array'
      or jsonb_array_length(p_plans) not between 1 and (c->>'max_entries')::integer then return false; end if;
    for p in select e from jsonb_array_elements(p_plans) e loop
      if jsonb_typeof(p) is distinct from 'object'
        or exists(select 1 from jsonb_object_keys(p) k where not c->'keys' ? k)
        or exists(select 1 from jsonb_array_elements_text(c->'keys') k where not p ? k)
        or jsonb_typeof(p->'id') is distinct from 'string' or (p->>'id') !~ (c->>'id_pattern') or (p->>'id')=any(ids)
        or jsonb_typeof(p->'name') is distinct from 'string' or btrim(p->>'name')=''
        -- UTF-16 code units, as Dart and JS count.
        or char_length(p->>'name')+regexp_count(p->>'name','[\U00010000-\U0010FFFF]')>(c->>'name_max_length')::integer
        or not public.valid_fee(p->'fee') or p->'fee'='{}'::jsonb then return false; end if;
      ids:=ids||(p->>'id');
    end loop;
  end if;
  if p_fee_plan is not null and (not p_fee_plan=any(ids) or p_fee is distinct from
      (select e->'fee' from jsonb_array_elements(p_plans) e where e->>'id'=p_fee_plan)) then return false; end if;
  for z in select e from jsonb_array_elements(case when jsonb_typeof(p_zones)='array' then p_zones else '[]'::jsonb end) e loop
    continue when jsonb_typeof(z) is distinct from 'object' or not z ? 'fee_plan';
    if jsonb_typeof(z->'fee_plan') is distinct from 'string' or not (z->>'fee_plan')=any(ids)
      or (z->'fee') is distinct from (select e->'fee' from jsonb_array_elements(p_plans) e where e->>'id'=z->>'fee_plan')
    then return false; end if;
  end loop;
  return true;
end;
$$;

-- ===== 欄位 =====

alter table public.community_spots add column fee_plans jsonb, add column fee_plan text;
alter table public.official_heavy_spots add column fee_plans jsonb, add column fee_plan text;

-- ===== 寫入時同步 =====

-- A plan name from a fee: its vehicles, then its mode when every rate that
-- does not follow another shares one (機車重機計時, 汽車時段), else 混合.
create function public.fee_plan_name(p_fee jsonb) returns text
language sql immutable set search_path='' as $$
  select coalesce(string_agg(v.label,'' order by v.o),'')
    ||case (select count(distinct e.value->>'mode') from jsonb_each(p_fee) e
        where e.value->>'mode' not in ('same_as_scooter','same_as_car'))
      when 0 then '比照'
      when 1 then (select case min(e.value->>'mode') when 'free' then '免費' when 'hourly' then '計時'
          when 'per_visit' then '計次' when 'daily' then '每日' when 'by_time' then '時段' else '未確認' end
        from jsonb_each(p_fee) e where e.value->>'mode' not in ('same_as_scooter','same_as_car'))
      else '混合' end
  from (values ('scooter','機車',1),('heavy','重機',2),('car','汽車',3)) v(key,label,o)
  where p_fee ? v.key;
$$;

-- p_fee as a plan of p_plans: the plan with the same fee, or a new one.
-- Returns {"plans": …, "id": …}.
create function public.fee_plans_absorb(p_plans jsonb,p_fee jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare
  v_plans jsonb:=coalesce(p_plans,'[]'::jsonb); v_id text; v_name text; n integer:=1; k integer:=2;
begin
  select e->>'id' into v_id from jsonb_array_elements(v_plans) e where e->'fee'=p_fee limit 1;
  if v_id is not null then return jsonb_build_object('plans',v_plans,'id',v_id); end if;
  while exists(select 1 from jsonb_array_elements(v_plans) e where e->>'id'='p'||n) loop n:=n+1; end loop;
  v_name:=public.fee_plan_name(p_fee);
  if exists(select 1 from jsonb_array_elements(v_plans) e where e->>'name'=v_name) then
    while exists(select 1 from jsonb_array_elements(v_plans) e where e->>'name'=v_name||' '||k) loop k:=k+1; end loop;
    v_name:=v_name||' '||k;
  end if;
  return jsonb_build_object('plans',v_plans||jsonb_build_array(jsonb_build_object('id','p'||n,'name',v_name,'fee',p_fee)),
    'id','p'||n);
end;
$$;

-- The fee, fee_plan, fee_plans and parking_zones a spot row p_new (as
-- jsonb; p_old the stored row on an update, null on insert) is written
-- with. A reference to an existing plan wins and its fee is copied, unless
-- a writer that knows nothing of plans changed the fee beside it (the fee
-- differs from the stored one while the plans did not change): that fee is
-- taken into a plan instead, as is any fee without a reference. A cleared
-- fee drops its reference. A reference to a missing plan beside no fee is
-- left for valid_fee_plans() to refuse.
create function public.fee_plans_sync(p_new jsonb,p_old jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare
  v_plans jsonb:=case when jsonb_typeof(p_new->'fee_plans')='array' then p_new->'fee_plans' end;
  v_fee jsonb:=nullif(p_new->'fee','null'::jsonb);
  v_plan text:=p_new->>'fee_plan';
  v_zones jsonb:=p_new->'parking_zones';
  v_same_plans boolean:=p_old is not null and (p_new->'fee_plans') is not distinct from (p_old->'fee_plans');
  -- What each zone does: 'copy' its plan's fee, 'take' its fee into a plan, or 'keep'.
  v_acts text[]:='{}'; v_take_top boolean:=false; v_legacy boolean:=false;
  v_keep text[]:='{}'; v_taken jsonb:='[]'; v_out jsonb:='[]'; r jsonb; z jsonb; pf jsonb; i integer:=0;
  v_n bigint; v_old_zone jsonb;
begin
  -- Plans that are not a list are left for the check to refuse.
  if p_new->'fee_plans' is not null and jsonb_typeof(p_new->'fee_plans') not in ('array','null') then
    return jsonb_build_object('fee',v_fee,'fee_plan',v_plan,'fee_plans',p_new->'fee_plans','parking_zones',v_zones);
  end if;
  pf:=(select e->'fee' from jsonb_array_elements(coalesce(v_plans,'[]')) e where e->>'id'=v_plan limit 1);
  if v_plan is not null and pf is not null and (p_old is null or v_plan is distinct from p_old->>'fee_plan'
      or v_fee is not distinct from nullif(p_old->'fee','null'::jsonb)) then
    v_fee:=pf; v_keep:=v_keep||v_plan;
  elsif jsonb_typeof(v_fee)='object' and v_fee<>'{}'::jsonb then
    v_take_top:=true; v_legacy:=true; v_taken:=v_taken||jsonb_build_array(v_fee);
  elsif v_plan is null or pf is not null then
    v_legacy:=v_plan is not null; v_plan:=null;
  else
    v_keep:=v_keep||v_plan;
  end if;

  for z,v_n in select e,x.n from jsonb_array_elements(case when jsonb_typeof(v_zones)='array' then v_zones else '[]'::jsonb end)
      with ordinality x(e,n) order by x.n loop
    pf:=case when jsonb_typeof(z)='object' and jsonb_typeof(z->'fee_plan')='string' then (select e->'fee'
      from jsonb_array_elements(coalesce(v_plans,'[]')) e where e->>'id'=z->>'fee_plan' limit 1) end;
    -- The stored zone at the same place: a reference the writer changed is
    -- an explicit choice of plan, never a fee edit to take in.
    v_old_zone:=case when jsonb_typeof(p_old->'parking_zones')='array' then p_old->'parking_zones'->(v_n::integer-1) end;
    if jsonb_typeof(z) is distinct from 'object' then v_acts:=v_acts||'keep'::text;
    elsif pf is not null and not (v_same_plans and (z->'fee_plan') is not distinct from (v_old_zone->'fee_plan')
        and jsonb_typeof(z->'fee')='object' and z->'fee'<>'{}'::jsonb and z->'fee'<>pf) then
      v_acts:=v_acts||'copy'::text; v_keep:=v_keep||(z->>'fee_plan');
    elsif jsonb_typeof(z->'fee')='object' and z->'fee'<>'{}'::jsonb then
      v_acts:=v_acts||'take'::text; v_legacy:=true; v_taken:=v_taken||jsonb_build_array(z->'fee');
    else
      v_acts:=v_acts||'keep'::text;
      if z ? 'fee_plan' then v_keep:=v_keep||(z->>'fee_plan'); end if;
    end if;
  end loop;

  -- A write that knows nothing of plans: the plans it no longer refers to
  -- go first (a fee it brings finds its plan again by content), so a fee
  -- that replaces another takes over the freed id and name.
  if v_legacy then
    v_plans:=(select jsonb_agg(e order by n) from jsonb_array_elements(coalesce(v_plans,'[]')) with ordinality x(e,n)
      where (e->>'id')=any(v_keep) or exists(select 1 from jsonb_array_elements(v_taken) t where t=e->'fee'));
  end if;
  if v_take_top then
    r:=public.fee_plans_absorb(v_plans,v_fee); v_plans:=r->'plans'; v_plan:=r->>'id';
  end if;
  for z in select e from jsonb_array_elements(case when jsonb_typeof(v_zones)='array' then v_zones else '[]'::jsonb end)
      with ordinality x(e,n) order by n loop
    i:=i+1;
    if v_acts[i]='copy' then
      z:=jsonb_set(z,'{fee}',(select e->'fee' from jsonb_array_elements(v_plans) e where e->>'id'=z->>'fee_plan' limit 1));
    elsif v_acts[i]='take' then
      r:=public.fee_plans_absorb(v_plans,z->'fee'); v_plans:=r->'plans';
      z:=jsonb_set(z,'{fee_plan}',to_jsonb(r->>'id'));
    end if;
    v_out:=v_out||jsonb_build_array(z);
  end loop;
  if jsonb_typeof(v_zones)='array' then v_zones:=v_out; end if;
  if jsonb_typeof(v_plans)='array' and jsonb_array_length(v_plans)=0 then v_plans:=null; end if;
  return jsonb_build_object('fee',v_fee,'fee_plan',v_plan,'fee_plans',v_plans,'parking_zones',v_zones);
end;
$$;
revoke execute on function public.fee_plans_sync(jsonb,jsonb) from public,anon,authenticated;

create function public.spot_fee_plans_sync() returns trigger
language plpgsql set search_path='' as $$
declare r jsonb;
begin
  r:=public.fee_plans_sync(to_jsonb(new),case when tg_op='UPDATE' then to_jsonb(old) end);
  new.fee:=nullif(r->'fee','null'::jsonb);
  -- A fee the plans changed (an edited plan) keeps its text in step when
  -- the text was the old fee's sentence and the writer left it alone.
  if tg_op='UPDATE' and new.fee is distinct from old.fee and new.fee_note is not distinct from old.fee_note
     and jsonb_typeof(old.fee)='object' and old.fee_note=public.fee_note_of(old.fee) then
    new.fee_note:=public.fee_note_of(new.fee);
  end if;
  new.fee_plan:=r->>'fee_plan';
  new.fee_plans:=nullif(r->'fee_plans','null'::jsonb);
  new.parking_zones:=r->'parking_zones';
  return new;
end;
$$;
create trigger community_spots_fee_plans before insert or update on public.community_spots
  for each row execute function public.spot_fee_plans_sync();
create trigger official_heavy_spots_fee_plans before insert or update on public.official_heavy_spots
  for each row execute function public.spot_fee_plans_sync();

-- Zones without their plan references, as files and older writers send them.
create function public.zones_without_plans(p_zones jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_zones)='array'
    then coalesce((select jsonb_agg(case when jsonb_typeof(z)='object' then z-'fee_plan' else z end order by n)
      from jsonb_array_elements(p_zones) with ordinality x(z,n)),'[]'::jsonb)
    else p_zones end;
$$;

-- ===== 既有資料與檢查 =====

-- Every fee becomes a plan: the trigger takes the stored fees in (one
-- statement per table, so #108's data_versions moves once each).
update public.community_spots set fee_plans=fee_plans
  where jsonb_typeof(fee)='object' and fee<>'{}'::jsonb
    or exists(select 1 from jsonb_array_elements(parking_zones) z where jsonb_typeof(z->'fee')='object' and z->'fee'<>'{}'::jsonb);
update public.official_heavy_spots set fee_plans=fee_plans
  where jsonb_typeof(fee)='object' and fee<>'{}'::jsonb
    or exists(select 1 from jsonb_array_elements(parking_zones) z where jsonb_typeof(z->'fee')='object' and z->'fee'<>'{}'::jsonb);

alter table public.community_spots add constraint community_spots_fee_plans_check
  check (public.valid_fee_plans(fee_plans,fee_plan,fee,parking_zones)) not valid;
alter table public.community_spots validate constraint community_spots_fee_plans_check;
alter table public.official_heavy_spots add constraint official_heavy_spots_fee_plans_check
  check (public.valid_fee_plans(fee_plans,fee_plan,fee,parking_zones)) not valid;
alter table public.official_heavy_spots validate constraint official_heavy_spots_fee_plans_check;

-- ===== 匯入 =====

-- 202610270022_fee_v2_core.sql's admin_import_plan, comparing the stored
-- zones without their plan references, which files never carry. Same
-- signature, so its grants stay.
create or replace function public.admin_import_plan(p_spots jsonb)
returns table(source_id text,kind text,target uuid,status text,reason text,name text,city text,district text,
  base_updated_at timestamptz,hidden boolean,incoming jsonb,changes jsonb)
language plpgsql stable set search_path=public,pg_temp as $$
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
    select coalesce(jsonb_agg(case
        when c->>'field' in ('fee','fee_note') and jsonb_typeof(c->'admin') is distinct from 'object'
        then c||jsonb_build_object('admin',(select p->'admin' from jsonb_array_elements(changes) p
          where p->>'field' in ('fee','fee_note') and jsonb_typeof(p->'admin')='object' limit 1))
        else c end order by o),'[]')
      into changes from jsonb_array_elements(changes) with ordinality as e(c,o);
    status:=case when changes='[]'::jsonb then 'unchanged'
      when exists(select 1 from jsonb_array_elements(changes) c where jsonb_typeof(c->'admin')='object') then 'conflict'
      else 'update' end;
    return next;
  end loop;
end;
$$;
