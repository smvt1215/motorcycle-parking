-- 統一 API 層的 schema 骨架（#195 P1；202611010300_api_schemas.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select has_schema('api_v1');
select has_schema('admin_v1');
select has_schema('private');

-- Schema usage: anon reaches api_v1 only; private is the owner's alone.
select ok(has_schema_privilege('anon', 'api_v1', 'usage'), 'anon can use api_v1');
select ok(has_schema_privilege('authenticated', 'api_v1', 'usage'), 'authenticated can use api_v1');
select ok(not has_schema_privilege('anon', 'admin_v1', 'usage'), 'anon cannot use admin_v1');
select ok(has_schema_privilege('authenticated', 'admin_v1', 'usage'), 'authenticated can use admin_v1 (each function checks the admin)');
select ok(not has_schema_privilege('anon', 'private', 'usage'), 'anon cannot use private');
select ok(not has_schema_privilege('authenticated', 'private', 'usage'), 'authenticated cannot use private');

-- The guard every later API migration relies on: no function in these
-- schemas may keep the built-in EXECUTE for PUBLIC (an ACL left at its
-- default, or an entry whose grantee is PUBLIC). Each must revoke it and
-- grant its roles explicitly.
select ok(
  p.proacl is not null
    and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  n.nspname || '.' || p.proname || ' is not executable by PUBLIC')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('api_v1', 'admin_v1', 'private');

-- private.require_admin(): stable error code for admin_v1.
create function pg_temp.act(who text) returns void language sql as $$
  select set_config('request.jwt.claims', case who
    when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
    when 'admin_aal1' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}'
    else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
  end, true);
$$;
select pg_temp.act('admin');
select lives_ok($$select private.require_admin()$$, 'an admin with a second factor passes');
select pg_temp.act('admin_aal1');
select throws_ok($$select private.require_admin()$$, 'PT403', 'auth.aal2_required', 'an admin without a second factor is refused');
select pg_temp.act('user');
select throws_ok($$select private.require_admin()$$, 'PT403', 'auth.aal2_required', 'an ordinary user is refused');
select ok(not has_function_privilege('authenticated', 'private.require_admin()', 'execute'), 'clients cannot call require_admin directly');

-- api_v1.client_config(): anon can read it and it names every dataset version.
set local role anon;
select ok((select api_v1.client_config() ? 'min_supported_app_version'), 'client_config names the minimum app version');
select is((select (api_v1.client_config()->>'rules_version')::bigint),
  (select version from public.data_versions where key = 'rules'), 'client_config carries the rules version');
select is((select (api_v1.client_config()->>'spots_version')::bigint),
  (select version from public.data_versions where key = 'spots'), 'client_config carries the spots version');
select is((select api_v1.client_config()->'availability_beta_cities'), '["臺北市"]'::jsonb,
  'the Taipei pilot is Beta');
reset role;

-- Ending or widening the Beta is data: enabled Beta sources, each city once.
insert into public.availability_sources(key, provider, feed_url, cities, vehicles,
  expected_interval, delayed_within, beta)
select 'test_beta', 'x', 'https://example.test/feed', array['臺北市', '新北市'], array['scooter'],
  expected_interval, delayed_within, true
from public.availability_sources where key = 'taipei_tcmsv';
select is((select api_v1.client_config()->'availability_beta_cities'), '["新北市", "臺北市"]'::jsonb,
  'Beta cities are listed once each, by name');
update public.availability_sources set enabled = false where key = 'test_beta';
update public.availability_sources set beta = false where key = 'taipei_tcmsv';
select is((select api_v1.client_config()->'availability_beta_cities'), '[]'::jsonb,
  'no Beta left reads as an empty list, not null');

select * from finish();
rollback;
