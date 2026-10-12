-- Official heavy-motorcycle bays in a map viewport, shaped like ParkingSpot
-- JSON. Rows take effect on their effective_date; RLS still applies.
create function public.official_viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id
  limit 501;
$$;
grant execute on function public.official_viewport_spots(double precision,double precision,double precision,double precision) to anon,authenticated;
