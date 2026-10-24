-- Space kinds a rider meets beyond the original five, from Taipei's official
-- street-space codes (pktype 04/18, 20, 22) and electric-motorcycle bays.
-- Scooter areas (pktype 11) are motorcycle bays, paid or free like them.
alter table public.community_spots drop constraint community_spots_space_type_check;
alter table public.community_spots add constraint community_spots_space_type_check
  check (space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet',
    'disabledMotorcycle','timedMotorcycle','flexShared','evMotorcycle'));
alter table public.official_heavy_spots drop constraint official_heavy_spots_space_type_check;
alter table public.official_heavy_spots add constraint official_heavy_spots_space_type_check
  check (space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet',
    'disabledMotorcycle','timedMotorcycle','flexShared','evMotorcycle'));

-- Installed builds that predate these kinds parse every row's space_type and
-- fail the whole map on one they do not know. They call the original RPCs,
-- which therefore keep returning the original five kinds only; current
-- builds call the _v2 functions, which return every kind.
create function public.viewport_spots_v2(south double precision,west double precision,north double precision,east double precision)
returns setof public.public_spots language sql stable security invoker
set search_path=public,extensions as $$
  select p.* from public.community_spots s join public.public_spots p on p.id=s.id
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and s.location operator(extensions.&&)
      extensions.st_makeenvelope($2,$1,$4,$3,4326)::extensions.geography
    and s.lat between $1 and $3 and s.lng between $2 and $4
  order by p.id
  limit 501;
$$;
grant execute on function public.viewport_spots_v2(double precision,double precision,double precision,double precision) to anon,authenticated;
create or replace function public.viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns setof public.public_spots language sql stable security invoker
set search_path=public,extensions as $$
  select p.* from public.community_spots s join public.public_spots p on p.id=s.id
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and s.location operator(extensions.&&)
      extensions.st_makeenvelope($2,$1,$4,$3,4326)::extensions.geography
    and s.lat between $1 and $3 and s.lng between $2 and $4
    and s.space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet')
  order by p.id
  limit 501;
$$;

create function public.official_viewport_spots_v2(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id
  limit 501;
$$;
grant execute on function public.official_viewport_spots_v2(double precision,double precision,double precision,double precision) to anon,authenticated;
create or replace function public.official_viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
    and o.space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet')
  order by o.id
  limit 501;
$$;
