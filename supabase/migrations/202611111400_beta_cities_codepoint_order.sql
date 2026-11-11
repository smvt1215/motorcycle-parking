-- availability_beta_cities is sorted by Unicode code point, not by the
-- database's default collation, so a local stack, staging and production
-- answer in the same order (#251). Only the ORDER BY changes; the rest is
-- client_config() as 202611011547_min_app_version.sql defined it.
create or replace function api_v1.client_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'min_supported_app_version', private.min_supported_app_version(),
    'rules_version', (select version from public.data_versions where key = 'rules'),
    'spots_version', (select version from public.data_versions where key = 'spots'),
    -- Cities whose live counts are still Beta, by name, each once.
    'availability_beta_cities', (
      select coalesce(jsonb_agg(city order by city collate "C"), '[]'::jsonb)
      from (
        select distinct unnest(cities) as city
        from public.availability_sources
        where enabled and beta
      ) beta_cities
    )
  );
$$;
revoke execute on function api_v1.client_config() from public;
grant execute on function api_v1.client_config() to anon, authenticated, service_role;
