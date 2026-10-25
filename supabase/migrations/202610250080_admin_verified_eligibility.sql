-- Admin-verified vehicle access on community spots.
--
-- A confirmed community spot proves the place exists (two riders may confirm
-- it by voting "still there"), not that its vehicle fields are right, so the
-- app keeps a community lot "unverified" for every vehicle. An administrator
-- who sets those fields in Admin Web has checked them, and the app may then
-- trust them like official data. Each vehicle keeps its own time:
--   scooter_verified_at / heavy_verified_at = when an admin last set that
--   vehicle's access (its *_allowed flag, or parking_access, which states
--   both), and null when no admin ever did or a later non-admin write changed
--   what was verified.
-- Only this trigger writes the columns. Nothing a rider sends (reports, votes,
-- the service role's import) can set them, because the trigger takes them
-- from the old row and only an admin JWT with a second factor
-- (public.is_admin()) records a new time.

alter table public.community_spots
  add column scooter_verified_at timestamptz,
  add column heavy_verified_at timestamptz;

-- Backfill from the audit log, conservatively. A vehicle counts as verified
-- only when an admin write (create_spot / update_spot, or an accepted report
-- applied to the spot) set its flag or parking_access to a non-null value,
-- and the row still holds exactly what that write left in every field the
-- verification covers. The time is the audit entry's, so the app's 180-day
-- freshness rule counts from the real check. Runs before the trigger exists.
with entries as (
  select a.created_at,
    case when a.action='resolve_report' then a.before->'spot' else a.before end as old_row,
    case when a.action='resolve_report' then a.after->'spot' else a.after end as new_row
  from public.admin_audit_log a
  where (a.action in ('create_spot','update_spot') and a.target_table='community_spots')
     or (a.action='resolve_report' and a.after->>'spot_table'='community_spots'
         and a.after->>'status'='accepted')
),
current_rows as (
  select c.id,jsonb_build_object('scooter_allowed',c.scooter_allowed,'heavy_allowed',c.heavy_allowed,
    'parking_access',c.parking_access,'space_type',c.space_type,'facility_type',c.facility_type,
    'lat',c.lat,'lng',c.lng) as now_row
  from public.community_spots c
),
verified as (
  select cur.id,v.flag,max(e.created_at) as at
  from entries e
  join current_rows cur on cur.id::text=e.new_row->>'id'
  cross join (values('scooter_allowed'),('heavy_allowed')) v(flag)
  where jsonb_typeof(e.new_row->v.flag)='boolean'
    and (e.old_row is null
      or (e.old_row->v.flag) is distinct from (e.new_row->v.flag)
      or (e.old_row->'parking_access') is distinct from (e.new_row->'parking_access'))
    -- The row still holds what the admin left.
    and not exists(select 1 from jsonb_object_keys(cur.now_row) k
      where (e.new_row->k) is distinct from (cur.now_row->k))
    -- No later admin write left something else there (a non-admin path
    -- must have restored the values since, so the check no longer holds).
    and not exists(select 1 from entries later
      where later.new_row->>'id'=e.new_row->>'id' and later.created_at>e.created_at
        and exists(select 1 from jsonb_object_keys(cur.now_row) k
          where (later.new_row->k) is distinct from (cur.now_row->k)))
  group by cur.id,v.flag
)
update public.community_spots c
  set scooter_verified_at=(select at from verified where verified.id=c.id and flag='scooter_allowed'),
      heavy_verified_at=(select at from verified where verified.id=c.id and flag='heavy_allowed')
  where c.id in (select id from verified);

create function public.community_spots_vehicle_verification() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_admin boolean:=coalesce(public.is_admin(),false);
  v_place boolean;
begin
  if tg_op='INSERT' then
    new.scooter_verified_at:=case when v_admin then now() end;
    new.heavy_verified_at:=case when v_admin then now() end;
  else
    -- Never taken from the write itself.
    new.scooter_verified_at:=old.scooter_verified_at;
    new.heavy_verified_at:=old.heavy_verified_at;
    if v_admin then
      -- Setting a vehicle's access, or the shared access that states both.
      if new.scooter_allowed is distinct from old.scooter_allowed
         or new.parking_access is distinct from old.parking_access then
        new.scooter_verified_at:=now();
      end if;
      if new.heavy_allowed is distinct from old.heavy_allowed
         or new.parking_access is distinct from old.parking_access then
        new.heavy_verified_at:=now();
      end if;
    else
      -- Anything else that changes what was verified voids it: the flag
      -- itself, the shared access, or which bay or place it describes.
      v_place:=new.parking_access is distinct from old.parking_access
        or new.space_type is distinct from old.space_type
        or new.facility_type is distinct from old.facility_type
        or new.lat is distinct from old.lat or new.lng is distinct from old.lng;
      if v_place or new.scooter_allowed is distinct from old.scooter_allowed then
        new.scooter_verified_at:=null;
      end if;
      if v_place or new.heavy_allowed is distinct from old.heavy_allowed then
        new.heavy_verified_at:=null;
      end if;
    end if;
  end if;
  -- An unknown flag has nothing to verify.
  if new.scooter_allowed is null then new.scooter_verified_at:=null; end if;
  if new.heavy_allowed is null then new.heavy_verified_at:=null; end if;
  return new;
end;
$$;
revoke execute on function public.community_spots_vehicle_verification() from public,anon,authenticated,service_role;
create trigger community_spots_vehicle_verification before insert or update on public.community_spots
  for each row execute function public.community_spots_vehicle_verification();

grant select (scooter_verified_at,heavy_verified_at) on public.community_spots to anon,authenticated;
-- 202610250050_contributor_attribution.sql's view plus the two times. The
-- viewport RPCs return setof this view, so they carry them too; older builds
-- ignore the extra keys and keep judging these spots unverified.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at
  from public.community_spots;
