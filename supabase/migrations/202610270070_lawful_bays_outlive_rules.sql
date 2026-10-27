-- Decision 44 (2026-10-27): a city rule that ended voids only the bays it
-- opened. A heavy bike on a heavy-bike bay or a car bay parks there by law
-- (docs/designs/2026-10-26-parking-conditions-and-fees.md §3.2 step 1), so
-- those bays are judged by the ended rule as before it ended, instead of
-- reading 「此地區的規則已過期」.
--
-- 1. rule_verdict(): when no rule is in force and every started rule is a
--    heavy-bike rule judging heavyOnly or car, the started rules answer.
--    The same as ruleVerdict() in lib/domain/parking_decision.dart and
--    supabase/functions/_shared/rule_verdict.ts; all three run
--    supabase/functions/_shared/rule_verdict_cases.json.
-- 2. The conservative projection old builds read (`city_rules`, from
--    202610270030): an expired heavy-bike row keeps heavyOnly and car in
--    allowed_space_types when the row allowed them outright (not by
--    district); everything else it opened stays conditional and
--    'unverified' as before.

create or replace function public.rule_verdict(p_rules jsonb,p_kind text,p_district text,p_now timestamptz)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
  v_day date:=(p_now at time zone 'Asia/Taipei')::date;
  v_rule jsonb; v_one jsonb; v_out jsonb; v_started boolean:=false;
  v_lawful boolean:=p_kind in ('heavyOnly','car');
begin
  for v_rule in select e from jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) e loop
    continue when (v_rule->>'effective_date')::date>v_day;
    v_started:=true;
    v_lawful:=v_lawful and v_rule->>'vehicle' is not distinct from 'heavy';
    continue when v_rule->>'expires_on' is not null and v_day>=(v_rule->>'expires_on')::date;
    v_one:=public.rule_verdict_one(v_rule,p_kind,coalesce(p_district,''));
    if v_out is null then v_out:=v_one;
    elsif v_out<>v_one then return '{"verdict":"conflict","restriction":null}';
    end if;
  end loop;
  if not v_started then return '{"verdict":"noRule","restriction":null}'; end if;
  if v_out is null and v_lawful then
    -- Every started rule has ended: on a lawful bay they answer as before.
    for v_rule in select e from jsonb_array_elements(p_rules) e loop
      continue when (v_rule->>'effective_date')::date>v_day;
      v_one:=public.rule_verdict_one(v_rule,p_kind,coalesce(p_district,''));
      if v_out is null then v_out:=v_one;
      elsif v_out<>v_one then return '{"verdict":"conflict","restriction":null}';
      end if;
    end loop;
  end if;
  return coalesce(v_out,'{"verdict":"expired","restriction":null}');
end $$;
revoke all on function public.rule_verdict(jsonb,text,text,timestamptz) from public,anon,authenticated;

create or replace view public.city_rules with (security_invoker=on) as
select r.city,r.vehicle,
  case when x.expired then (
      select coalesce(jsonb_agg(t order by t),'[]'::jsonb)
      from jsonb_array_elements_text(r.allowed_space_types) t
      where r.vehicle='heavy' and t in ('heavyOnly','car')
        and not r.district_space_types ? t)
    else r.allowed_space_types end as allowed_space_types,
  case when x.expired then (
      select coalesce(jsonb_agg(t order by t),'[]'::jsonb) from (
        select jsonb_array_elements_text(r.allowed_space_types) t
        union select jsonb_array_elements_text(r.conditional_space_types)
        union select jsonb_object_keys(r.district_space_types)) u
      where not (r.vehicle='heavy' and t in ('heavyOnly','car')
        and r.allowed_space_types ? t and not r.district_space_types ? t))
    else r.conditional_space_types end as conditional_space_types,
  r.districts,r.fee_note,
  case when x.expired then '此地區的規則已過期，請以現場標誌標線為準' else r.exceptions end as exceptions,
  r.can_use_two_spaces,r.effective_date,r.source_url,r.version,
  case when x.expired then 'unverified' else r.restriction end as restriction,
  case when x.expired then '{}'::jsonb else r.district_space_types end as district_space_types,
  r.expires_on
from public.city_rules_v2() r
cross join lateral (select r.expires_on is not null
  and r.expires_on<=(now() at time zone 'Asia/Taipei')::date as expired) x;
revoke all on public.city_rules from anon,authenticated;
grant select on public.city_rules to anon,authenticated;
