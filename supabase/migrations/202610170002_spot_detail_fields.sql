-- Columns behind the twelve detail fields (DESIGN.md「點位詳情十二欄分組版」)
-- for both community and official spots. Live availability stays out of scope.
alter table public.community_spots
  add column facility_type text check (facility_type in ('multiStorey','underground','surface','roadside')),
  add column parking_access text check (parking_access in ('scooterOnly','scooterHeavy','heavyCar','noMotorcycle','heavyOnly')),
  add column address text not null default '' check (char_length(address)<=200),
  add column road_segment text not null default '' check (char_length(road_segment)<=200),
  add column entrance_note text not null default '' check (char_length(entrance_note)<=500),
  add column parking_guide text not null default '' check (char_length(parking_guide)<=500),
  add column special_rules text not null default '' check (char_length(special_rules)<=500),
  add column photo_urls jsonb not null default '[]' check (
    jsonb_typeof(photo_urls)='array' and jsonb_array_length(photo_urls)<=10
    and not jsonb_path_exists(photo_urls,'$[*] ? (@.type() != "string" || !(@ like_regex "^https://"))')),
  add column parking_zones jsonb not null default '[]' check (jsonb_typeof(parking_zones)='array');

alter table public.official_heavy_spots
  add column facility_type text check (facility_type in ('multiStorey','underground','surface','roadside')),
  add column parking_access text check (parking_access in ('scooterOnly','scooterHeavy','heavyCar','noMotorcycle','heavyOnly')),
  add column address text not null default '' check (char_length(address)<=200),
  add column road_segment text not null default '' check (char_length(road_segment)<=200),
  add column scooter_total integer check (scooter_total>=0),
  add column entrance_note text not null default '' check (char_length(entrance_note)<=500),
  add column parking_guide text not null default '' check (char_length(parking_guide)<=500),
  add column special_rules text not null default '' check (char_length(special_rules)<=500),
  add column photo_urls jsonb not null default '[]' check (
    jsonb_typeof(photo_urls)='array' and jsonb_array_length(photo_urls)<=10
    and not jsonb_path_exists(photo_urls,'$[*] ? (@.type() != "string" || !(@ like_regex "^https://"))')),
  add column parking_zones jsonb not null default '[]' check (jsonb_typeof(parking_zones)='array'),
  add column license_note text not null default '' check (char_length(license_note)<=200);

-- Clients read every public column but user_id; the new columns join that list.
grant select (facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,photo_urls,parking_zones)
  on public.community_spots to anon,authenticated;

-- New columns go at the end so existing view consumers keep their positions.
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,photo_urls,parking_zones
  from public.community_spots;

-- The result shape changes, so the function is replaced rather than altered.
drop function public.official_viewport_spots(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots(south double precision,west double precision,north double precision,east double precision)
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
grant execute on function public.official_viewport_spots(double precision,double precision,double precision,double precision) to anon,authenticated;
