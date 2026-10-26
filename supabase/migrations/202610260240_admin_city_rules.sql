-- Admin web P5 (docs/ADMIN_WEB.md): publish a city rule through one audited
-- RPC. The server owns the version number, so two admins cannot both publish
-- "version 3", and a publish over a version the admin did not open is refused.
-- Rules change only through that RPC: admins lose direct writes, so every
-- change is versioned, audited and kept in the history below. Reads stay
-- public; the service role (Dashboard SQL, emergencies) still bypasses this
-- and leaves no audit entry.
drop policy admin_rules on public.city_rules;
revoke insert,update,delete on public.city_rules from anon,authenticated;

-- Every version a publish replaces, so a later reader (rule evidence, the
-- rule prescreen engine of CONTRIBUTION_TIERS_FEASIBILITY.md §5.7) can tell
-- what a past version said. Only admin_upsert_city_rule writes it; admins read.
create table public.city_rules_history (
  id bigint generated always as identity primary key,
  city text not null,
  vehicle text not null check (vehicle in ('scooter','heavy')),
  version integer not null check (version>0),
  row jsonb not null check (jsonb_typeof(row)='object'),
  replaced_at timestamptz not null default now(),
  replaced_by uuid not null,
  unique (city,vehicle,version)
);
alter table public.city_rules_history enable row level security;
revoke all on public.city_rules_history from anon,authenticated;
grant select on public.city_rules_history to authenticated;
create policy admin_read_rule_history on public.city_rules_history for select to authenticated
  using((select public.is_admin()));
create function public.city_rules_history_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
  raise exception 'rule history cannot be changed' using errcode='42501';
end;
$$;
create trigger city_rules_history_immutable before update or delete on public.city_rules_history
  for each row execute function public.city_rules_history_immutable();
create trigger city_rules_history_no_truncate before truncate on public.city_rules_history
  for each statement execute function public.city_rules_history_immutable();

create function public.admin_upsert_city_rule(
  p_city text, p_vehicle text, p_values jsonb,
  p_base_version integer default null, p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_values jsonb:=coalesce(p_values,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_fields text[]:=array['allowed_space_types','conditional_space_types','districts',
    'district_space_types','fee_note','exceptions','can_use_two_spaces','effective_date',
    'source_url','restriction'];
  -- The original five kinds only: builds before #51 fail to parse any other
  -- kind in a rule, and the newer kinds follow the law or the bay itself.
  v_types text[]:=array['paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet'];
  v_cities text[]:=array['全國','臺北市','新北市','基隆市','桃園市','新竹市','新竹縣','苗栗縣',
    '臺中市','彰化縣','南投縣','雲林縣','嘉義市','嘉義縣','臺南市','高雄市','屏東縣',
    '宜蘭縣','花蓮縣','臺東縣','澎湖縣','金門縣','連江縣'];
  v_old city_rules; v_new city_rules; v_exists boolean; v_merged jsonb; v_bad text; v_list jsonb; v_street jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_city is null or p_city<>all(v_cities) then
    raise exception 'unknown city' using errcode='22023';
  end if;
  if p_vehicle is null or p_vehicle not in ('scooter','heavy') then
    raise exception 'unknown vehicle' using errcode='22023';
  end if;
  if jsonb_typeof(v_values)<>'object' or char_length(v_note)>500 then
    raise exception 'invalid rule' using errcode='22023';
  end if;
  select k into v_bad from jsonb_object_keys(v_values) k where k<>all(v_fields) limit 1;
  if v_bad is not null then raise exception 'field % is not editable', v_bad using errcode='22023'; end if;

  select * into v_old from city_rules where city=p_city and vehicle=p_vehicle for update;
  v_exists:=found;
  if p_base_version is distinct from (case when v_exists then v_old.version end) then
    raise exception 'rule changed since it was opened' using errcode='40001';
  end if;
  -- Absent fields keep the current value; a new rule must name them all
  -- except the lists, the two-space flag and the restriction.
  v_merged:=case when not v_exists then
      '{"conditional_space_types":["offStreet"],"districts":[],"district_space_types":{},"can_use_two_spaces":false,"restriction":null}'::jsonb
    else to_jsonb(v_old) end || v_values;

  foreach v_bad in array array['allowed_space_types','conditional_space_types','districts'] loop
    v_list:=v_merged->v_bad;
    if v_list is null or jsonb_typeof(v_list)<>'array' then
      raise exception '% must be a list', v_bad using errcode='22023';
    end if;
  end loop;
  if exists(select 1 from jsonb_array_elements((v_merged->'allowed_space_types')||(v_merged->'conditional_space_types')) e
            where jsonb_typeof(e)<>'string' or e#>>'{}'<>all(v_types)) then
    raise exception 'unknown space type' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements_text(v_merged->'allowed_space_types') a
            join jsonb_array_elements_text(v_merged->'conditional_space_types') c on a=c)
     or (select count(*)<>count(distinct e) from jsonb_array_elements_text(v_merged->'allowed_space_types') e)
     or (select count(*)<>count(distinct e) from jsonb_array_elements_text(v_merged->'conditional_space_types') e) then
    raise exception 'a space type is listed twice' using errcode='22023';
  end if;
  -- District names: listed once, as short text.
  if exists(select 1 from jsonb_array_elements(v_merged->'districts') e
            where jsonb_typeof(e)<>'string' or char_length(e#>>'{}') not between 1 and 20)
     or jsonb_array_length(v_merged->'districts')>50
     or (select count(*)<>count(distinct e) from jsonb_array_elements_text(v_merged->'districts') e) then
    raise exception 'invalid districts' using errcode='22023';
  end if;
  v_list:=v_merged->'district_space_types';
  if v_list is null or jsonb_typeof(v_list)<>'object'
     or exists(select 1 from jsonb_each(v_list) d where d.key<>all(v_types)
       or jsonb_typeof(d.value)<>'array' or jsonb_array_length(d.value) not between 1 and 50
       or exists(select 1 from jsonb_array_elements(d.value) e
                 where jsonb_typeof(e)<>'string' or char_length(e#>>'{}') not between 1 and 20)
       or (select count(*)<>count(distinct e) from jsonb_array_elements_text(d.value) e)) then
    raise exception 'invalid district space types' using errcode='22023';
  end if;

  if jsonb_typeof(v_merged->'fee_note') is distinct from 'string'
     or char_length(v_merged->>'fee_note') not between 1 and 200 then
    raise exception 'fee note must be 1-200 characters' using errcode='22023';
  end if;
  if jsonb_typeof(v_merged->'exceptions') is distinct from 'string'
     or char_length(v_merged->>'exceptions') not between 1 and 500 then
    raise exception 'exceptions must be 1-500 characters' using errcode='22023';
  end if;
  if jsonb_typeof(v_merged->'source_url') is distinct from 'string'
     or v_merged->>'source_url' !~ '^https://[^[:space:]]+$' or char_length(v_merged->>'source_url')>500 then
    raise exception 'source url must be https' using errcode='22023';
  end if;
  if jsonb_typeof(v_merged->'can_use_two_spaces') is distinct from 'boolean' then
    raise exception 'can_use_two_spaces must be true or false' using errcode='22023';
  end if;
  if jsonb_typeof(v_merged->'effective_date') is distinct from 'string'
     or v_merged->>'effective_date' !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'effective date must be YYYY-MM-DD' using errcode='22023';
  end if;
  begin
    perform (v_merged->>'effective_date')::date;
  exception when others then
    raise exception 'effective date must be YYYY-MM-DD' using errcode='22023';
  end;

  -- Same rule as city_rules_restriction_required, with a readable error;
  -- a restriction with no conditional street space would mean nothing.
  v_street:=(v_merged->'conditional_space_types')-'offStreet';
  if jsonb_typeof(v_merged->'restriction') not in ('string','null')
     or coalesce(v_merged->>'restriction','signage') not in ('pilot_area','signage','unverified') then
    raise exception 'unknown restriction' using errcode='22023';
  end if;
  if jsonb_array_length(v_street)>0 and v_merged->>'restriction' is null then
    raise exception 'conditional street spaces need a restriction' using errcode='23514';
  end if;
  if jsonb_array_length(v_street)=0 and v_merged->>'restriction' is not null then
    raise exception 'a restriction needs a conditional street space' using errcode='22023';
  end if;

  if v_exists and (to_jsonb(v_old)-'version')=(v_merged-'version') then
    raise exception 'rule unchanged' using errcode='22023';
  end if;

  insert into city_rules as r(city,vehicle,allowed_space_types,conditional_space_types,districts,
      district_space_types,fee_note,exceptions,can_use_two_spaces,effective_date,source_url,restriction,version)
    values(p_city,p_vehicle,v_merged->'allowed_space_types',v_merged->'conditional_space_types',
      v_merged->'districts',v_merged->'district_space_types',v_merged->>'fee_note',v_merged->>'exceptions',
      (v_merged->>'can_use_two_spaces')::boolean,(v_merged->>'effective_date')::date,
      v_merged->>'source_url',v_merged->>'restriction',coalesce(v_old.version,0)+1)
    on conflict(city,vehicle) do update set
      allowed_space_types=excluded.allowed_space_types,conditional_space_types=excluded.conditional_space_types,
      districts=excluded.districts,district_space_types=excluded.district_space_types,
      fee_note=excluded.fee_note,exceptions=excluded.exceptions,can_use_two_spaces=excluded.can_use_two_spaces,
      effective_date=excluded.effective_date,source_url=excluded.source_url,restriction=excluded.restriction,
      version=excluded.version
      -- A rule created by someone else between the check and this insert.
      where r.version=coalesce(v_old.version,0)
    returning * into v_new;
  if v_new is null then
    raise exception 'rule changed since it was opened' using errcode='40001';
  end if;

  if v_exists then
    insert into city_rules_history(city,vehicle,version,row,replaced_by)
      values(p_city,p_vehicle,v_old.version,to_jsonb(v_old),auth.uid());
  end if;
  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'upsert_city_rule','city_rules',p_city||':'||p_vehicle,
      case when v_exists then to_jsonb(v_old) end,to_jsonb(v_new),v_note);
  return to_jsonb(v_new);
end;
$$;
revoke execute on function public.admin_upsert_city_rule(text,text,jsonb,integer,text) from public,anon;
grant execute on function public.admin_upsert_city_rule(text,text,jsonb,integer,text) to authenticated;
