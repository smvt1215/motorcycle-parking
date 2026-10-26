-- Admin Web P4a-3 (docs/ADMIN_WEB.md「點位」): the spots page map. The app's
-- viewport functions run as the caller, so an admin would already see hidden
-- rows there, but without saying which are hidden, and official rows always
-- read 'confirmed'. This one names each row's layer and is for admins only.
--
-- Three independent layers: visible community spots, visible official spots
-- (future-dated ones included: admins prepare them), and hidden spots of
-- either kind. Each layer returns at most 501 rows, so the page can tell a
-- layer was cut off, as the app does with 500.
create function public.admin_viewport_spots(south double precision,west double precision,north double precision,east double precision,
  p_community boolean default true,p_official boolean default true,p_hidden boolean default false)
returns table(
  id text,source text,source_name text,source_url text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,scooter_total integer,
  scooter_allowed boolean,heavy_allowed boolean,status text,updated_at timestamptz,last_confirmed_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,fee jsonb,
  scooter_verified_at timestamptz,heavy_verified_at timestamptz,hidden boolean
)
language plpgsql stable security invoker set search_path=public,extensions,pg_temp as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  -- The same box the app accepts: finite, ordered, at most 0.5 degree a side.
  if not (south >= -90 and north <= 90 and west >= -180 and east <= 180
          and north > south and east > west and north-south <= 0.5 and east-west <= 0.5) then
    raise exception 'invalid viewport' using errcode='22023';
  end if;
  return query
  (select c.id::text,c.source,c.source_name,c.source_url,c.license_note,c.name,c.lat,c.lng,
          c.city,c.district,c.space_type,c.fee_note,c.note,c.scooter_total,
          c.scooter_allowed,c.heavy_allowed,c.status,c.updated_at,c.last_confirmed_at,
          c.facility_type,c.parking_access,c.address,c.road_segment,c.fee,
          c.scooter_verified_at,c.heavy_verified_at,false
     from community_spots c
    where p_community and c.status<>'hidden'
      and c.location operator(extensions.&&)
        extensions.st_makeenvelope(west,south,east,north,4326)::extensions.geography
      and c.lat between south and north and c.lng between west and east
    order by c.id limit 501)
  union all
  (select 'official:'||o.id,'official',o.source_name,o.source_url,o.license_note,o.name,o.lat,o.lng,
          o.city,o.district,o.space_type,o.fee_note,o.note,o.scooter_total,
          o.scooter_allowed,o.heavy_allowed,'confirmed',o.updated_at,null::timestamptz,
          o.facility_type,o.parking_access,o.address,o.road_segment,o.fee,
          null::timestamptz,null::timestamptz,false
     from official_heavy_spots o
    where p_official and not o.hidden
      and o.lat between south and north and o.lng between west and east
    order by o.id limit 501)
  union all
  (select * from (
     select c.id::text,c.source,c.source_name,c.source_url,c.license_note,c.name,c.lat,c.lng,
            c.city,c.district,c.space_type,c.fee_note,c.note,c.scooter_total,
            c.scooter_allowed,c.heavy_allowed,c.status,c.updated_at,c.last_confirmed_at,
            c.facility_type,c.parking_access,c.address,c.road_segment,c.fee,
            c.scooter_verified_at,c.heavy_verified_at,true
       from community_spots c
      where c.status='hidden'
        and c.location operator(extensions.&&)
          extensions.st_makeenvelope(west,south,east,north,4326)::extensions.geography
        and c.lat between south and north and c.lng between west and east
     union all
     select 'official:'||o.id,'official',o.source_name,o.source_url,o.license_note,o.name,o.lat,o.lng,
            o.city,o.district,o.space_type,o.fee_note,o.note,o.scooter_total,
            o.scooter_allowed,o.heavy_allowed,'confirmed',o.updated_at,null::timestamptz,
            o.facility_type,o.parking_access,o.address,o.road_segment,o.fee,
            null::timestamptz,null::timestamptz,true
       from official_heavy_spots o
      where o.hidden and o.lat between south and north and o.lng between west and east
   ) h where p_hidden order by h.id limit 501);
end;
$$;
revoke execute on function public.admin_viewport_spots(double precision,double precision,double precision,double precision,boolean,boolean,boolean) from public,anon;
grant execute on function public.admin_viewport_spots(double precision,double precision,double precision,double precision,boolean,boolean,boolean) to authenticated;
