-- Official parking lots imported from municipal open data and TDX share the
-- admin-maintained official table. Heavy access is null unless an official
-- source states it; manually entered heavy bays keep the true default.
alter table public.official_heavy_spots
  alter column heavy_allowed drop not null,
  add column source_name text not null default '' check (char_length(source_name)<=60),
  add column source_id text unique check (char_length(source_id) between 1 and 100),
  add column address text not null default '' check (char_length(address)<=200),
  add column facility_type text check (facility_type in ('multiStorey','underground','surface','roadside')),
  add column scooter_total integer check (scooter_total>=0),
  add column entrance_note text not null default '' check (char_length(entrance_note)<=500),
  add column parking_guide text not null default '' check (char_length(parking_guide)<=500),
  add column special_rules text not null default '' check (char_length(special_rules)<=500),
  add column parking_zones jsonb not null default '[]' check (jsonb_typeof(parking_zones)='array');

-- The result shape changes, so the function is replaced rather than altered.
drop function public.official_viewport_spots(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  address text,facility_type text,scooter_total integer,entrance_note text,parking_guide text,
  special_rules text,parking_zones jsonb
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.address,o.facility_type,o.scooter_total,o.entrance_note,o.parking_guide,
    o.special_rules,o.parking_zones
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id
  limit 501;
$$;
grant execute on function public.official_viewport_spots(double precision,double precision,double precision,double precision) to anon,authenticated;
