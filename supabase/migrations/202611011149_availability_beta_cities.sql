-- Official live availability starts as a Beta in 臺北市 (user decision,
-- PM_ASSIGN_20261101_67). The App labels those cities from
-- api_v1.client_config(), so ending the Beta is one row update and needs no
-- App release: update public.availability_sources set beta = false where ...

alter table public.availability_sources
  add column beta boolean not null default false;

update public.availability_sources set beta = true where key = 'taipei_tcmsv';

-- v1 grows by addition only: availability_beta_cities is new, every other
-- field is unchanged (#195 §2.1).
create or replace function api_v1.client_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'min_supported_app_version', '0.1.0',
    'rules_version', (select version from public.data_versions where key = 'rules'),
    'spots_version', (select version from public.data_versions where key = 'spots'),
    -- Cities whose live counts are still Beta, by name, each once.
    'availability_beta_cities', (
      select coalesce(jsonb_agg(city order by city), '[]'::jsonb)
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
