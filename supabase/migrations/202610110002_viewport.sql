-- Bounding-box lookup crosses city boundaries; RLS still applies.
create function public.viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns setof public.community_spots language sql stable security invoker
set search_path=public,extensions as $$
  select s.* from public.community_spots s
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and s.location operator(extensions.&&)
      extensions.st_makeenvelope($2,$1,$4,$3,4326)::extensions.geography
    and s.lat between $1 and $3 and s.lng between $2 and $4
  order by s.id
  limit 501;
$$;
grant execute on function public.viewport_spots(double precision,double precision,double precision,double precision) to anon,authenticated;
