-- Fee plan edges (#155 items 1–3, decision 51; design §2.6). Redefines
-- 202610270023_fee_plans.sql's fee_plans_sync() with three rules:
--
-- 1. A zone that keeps its fee_plan but no longer has a fee (no fee key,
--    fee JSON null or {}) is cleared: its reference goes with it (and a
--    JSON null fee key too), as a cleared top-level fee drops the spot's. Before, a missing key was
--    refused by the check (jsonb_typeof(z->'fee')='object' was NULL) and a
--    JSON null was filled back with the plan's fee.
-- 2. A zone is compared with the stored zone of the same name and area,
--    not the one at the same place, so deleting or reordering zones in the
--    write that edits a fee no longer reads as choosing another plan (and
--    loses the edit). Zones with the same name and area pair up in order; a
--    zone with no stored match is new.
-- 3. A write that changes fee_plans and removes a plan still referred to by
--    the spot or a zone that keeps its fee is refused ('fee plan in use',
--    23503, the plans and their counts as JSON in the detail) rather than
--    the plan coming back under a generated name. The admin site (C6)
--    disables delete for such a plan and reads the detail for
--    「N 個分區在用，先改掉引用」.
--
-- Same signature, so the grants (revoked from public, anon, authenticated)
-- and the triggers stay.

create or replace function public.fee_plans_sync(p_new jsonb,p_old jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare
  v_plans jsonb:=case when jsonb_typeof(p_new->'fee_plans')='array' then p_new->'fee_plans' end;
  v_fee jsonb:=nullif(p_new->'fee','null'::jsonb);
  v_plan text:=p_new->>'fee_plan';
  v_zones jsonb:=p_new->'parking_zones';
  v_new_zones jsonb:=case when jsonb_typeof(p_new->'parking_zones')='array' then p_new->'parking_zones' else '[]'::jsonb end;
  v_old_zones jsonb:=case when jsonb_typeof(p_old->'parking_zones')='array' then p_old->'parking_zones' else '[]'::jsonb end;
  v_same_plans boolean:=p_old is not null and (p_new->'fee_plans') is not distinct from (p_old->'fee_plans');
  -- What each zone does: 'copy' its plan's fee, 'take' its fee into a plan,
  -- 'clear' its reference, or 'keep'.
  v_acts text[]:='{}'; v_take_top boolean:=false; v_legacy boolean:=false;
  v_keep text[]:='{}'; v_taken jsonb:='[]'; v_out jsonb:='[]'; r jsonb; z jsonb; pf jsonb; i integer:=0;
  v_n bigint; v_old_zone jsonb; v_in_use jsonb;
begin
  -- Plans that are not a list are left for the check to refuse.
  if p_new->'fee_plans' is not null and jsonb_typeof(p_new->'fee_plans') not in ('array','null') then
    return jsonb_build_object('fee',v_fee,'fee_plan',v_plan,'fee_plans',p_new->'fee_plans','parking_zones',v_zones);
  end if;

  -- A plan the writer removed while the spot, or a zone that keeps a fee,
  -- still refers to it: refused, never rebuilt under a generated name.
  if p_old is not null and not v_same_plans then
    select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'zones',s.zones,'spot',s.spot) order by s.n) into v_in_use
    from (
      select o->>'id' id,o->>'name' name,x.n,
        (select count(*) from jsonb_array_elements(v_new_zones) e
          where jsonb_typeof(e)='object' and e->>'fee_plan'=o->>'id'
            and coalesce(jsonb_typeof(e->'fee'),'null')<>'null' and e->'fee'<>'{}'::jsonb) zones,
        coalesce(v_plan=o->>'id',false) spot
      from jsonb_array_elements(case when jsonb_typeof(p_old->'fee_plans')='array' then p_old->'fee_plans' else '[]'::jsonb end)
        with ordinality x(o,n)
      where jsonb_typeof(o)='object' and jsonb_typeof(o->'id')='string'
        and not exists(select 1 from jsonb_array_elements(coalesce(v_plans,'[]')) e
          where jsonb_typeof(e)='object' and e->>'id'=o->>'id')
    ) s where s.zones>0 or s.spot;
    if v_in_use is not null then
      raise exception 'fee plan in use' using errcode='23503',
        detail=jsonb_build_object('plans',v_in_use)::text,
        hint='change the spot or zones that refer to the plan first';
    end if;
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

  for z,v_n in select e,x.n from jsonb_array_elements(v_new_zones) with ordinality x(e,n) order by x.n loop
    pf:=case when jsonb_typeof(z)='object' and jsonb_typeof(z->'fee_plan')='string' then (select e->'fee'
      from jsonb_array_elements(coalesce(v_plans,'[]')) e where e->>'id'=z->>'fee_plan' limit 1) end;
    -- The stored zone of the same name and area (the k-th such zone for the
    -- k-th): a reference the writer changed is an explicit choice of plan,
    -- never a fee edit to take in. No stored match: a new zone.
    v_old_zone:=case when jsonb_typeof(z)='object' then (
      select o from jsonb_array_elements(v_old_zones) with ordinality y(o,m)
      where jsonb_typeof(o)='object' and (o->'name') is not distinct from (z->'name')
        and (o->'area') is not distinct from (z->'area')
      order by y.m offset (
        select count(*) from jsonb_array_elements(v_new_zones) with ordinality w(e,k)
        where w.k<v_n and jsonb_typeof(e)='object' and (e->'name') is not distinct from (z->'name')
          and (e->'area') is not distinct from (z->'area'))
      limit 1) end;
    if jsonb_typeof(z) is distinct from 'object' then v_acts:=v_acts||'keep'::text;
    elsif z ? 'fee_plan' and (coalesce(jsonb_typeof(z->'fee'),'null')='null' or z->'fee'='{}'::jsonb) then
      -- A cleared zone fee drops its reference (rule 1).
      v_acts:=v_acts||'clear'::text; v_legacy:=true;
    elsif pf is not null and not (v_same_plans and v_old_zone is not null
        and (z->'fee_plan') is not distinct from (v_old_zone->'fee_plan')
        and coalesce(jsonb_typeof(z->'fee'),'')='object' and z->'fee'<>pf) then
      v_acts:=v_acts||'copy'::text; v_keep:=v_keep||(z->>'fee_plan');
    elsif coalesce(jsonb_typeof(z->'fee'),'')='object' and z->'fee'<>'{}'::jsonb then
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
  for z in select e from jsonb_array_elements(v_new_zones) with ordinality x(e,n) order by n loop
    i:=i+1;
    if v_acts[i]='copy' then
      z:=jsonb_set(z,'{fee}',(select e->'fee' from jsonb_array_elements(v_plans) e where e->>'id'=z->>'fee_plan' limit 1));
    elsif v_acts[i]='take' then
      r:=public.fee_plans_absorb(v_plans,z->'fee'); v_plans:=r->'plans';
      z:=jsonb_set(z,'{fee_plan}',to_jsonb(r->>'id'));
    elsif v_acts[i]='clear' then
      -- A JSON null fee goes too: valid_zones() takes no null fee.
      z:=case when z->'fee'='null'::jsonb then z-'fee_plan'-'fee' else z-'fee_plan' end;
    end if;
    v_out:=v_out||jsonb_build_array(z);
  end loop;
  if jsonb_typeof(v_zones)='array' then v_zones:=v_out; end if;
  if jsonb_typeof(v_plans)='array' and jsonb_array_length(v_plans)=0 then v_plans:=null; end if;
  return jsonb_build_object('fee',v_fee,'fee_plan',v_plan,'fee_plans',v_plans,'parking_zones',v_zones);
end;
$$;
revoke execute on function public.fee_plans_sync(jsonb,jsonb) from public,anon,authenticated;
