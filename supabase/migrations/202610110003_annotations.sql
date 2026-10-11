-- Latest moderator-confirmed heavy-motorcycle annotation per TDX spot.
-- POST via RPC so up to 500 viewport ids never hit URL length limits.
create function public.confirmed_annotations(p_ids text[])
returns table(source_id text,heavy_access text,updated_at timestamptz)
language sql stable security invoker set search_path=public as $$
  select distinct on (a.source_id) a.source_id,a.heavy_access,a.updated_at
  from public.spot_annotations a
  where cardinality($1)<=500 and a.source='tdx' and a.status='confirmed'
    and a.source_id=any($1)
  order by a.source_id,a.updated_at desc;
$$;
grant execute on function public.confirmed_annotations(text[]) to anon,authenticated,service_role;
