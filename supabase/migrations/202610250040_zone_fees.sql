-- A zone uses the same fee contract as its lot: scooters and heavy bikes.
-- Legacy text stays intact; no existing prices are inferred or converted.
create function public.valid_zone_fees(p_zones jsonb) returns boolean
language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_zones) is distinct from 'array' then false else
    not exists(select 1 from jsonb_array_elements(p_zones) z
      where jsonb_typeof(z) is distinct from 'object'
        or (z ? 'fee' and not public.valid_fee(z->'fee'))) end;
$$;

alter table public.community_spots add constraint community_spots_zone_fees_check
  check (public.valid_zone_fees(parking_zones));
alter table public.official_heavy_spots add constraint official_spots_zone_fees_check
  check (public.valid_zone_fees(parking_zones));

-- Both community viewport functions return this view's composite type.
-- Appending a column keeps its existing consumers and grants in place.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee
  from public.community_spots;

-- A RETURNS TABLE shape cannot be altered in place. Preserve both versions,
-- their bounds, visibility policies, ordering and the legacy space filter.
drop function public.official_viewport_spots_v2(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots_v2(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id limit 501;
$$;
grant execute on function public.official_viewport_spots_v2(double precision,double precision,double precision,double precision) to anon,authenticated;

drop function public.official_viewport_spots(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
    and o.space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet')
  order by o.id limit 501;
$$;
grant execute on function public.official_viewport_spots(double precision,double precision,double precision,double precision) to anon,authenticated;
