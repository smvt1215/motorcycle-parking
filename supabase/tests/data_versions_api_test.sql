-- api_v1.data_versions() 與版本變動的 Broadcast（#195 P2；202611011920_api_v1_data_versions.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

set local role anon;
select is(api_v1.data_versions(),
  (select jsonb_object_agg(key, version) from public.data_versions), 'anon reads every dataset version');
select ok(api_v1.data_versions() ? 'rules' and api_v1.data_versions() ? 'spots', 'rules and spots are listed');
select is((api_v1.data_versions()->>'rules')::bigint, (api_v1.client_config()->>'rules_version')::bigint,
  'data_versions and client_config agree');
reset role;

-- A bump is broadcast on the public topic for subscribed Apps.
update public.data_versions set version = version + 1 where key = 'rules';
select is((select count(*)::int from realtime.messages
  where topic = 'data_versions' and event = 'bump' and not private
    and payload->>'key' = 'rules'
    and (payload->>'version')::bigint = (select version from public.data_versions where key = 'rules')),
  1, 'the new rules version is broadcast publicly');
-- An update that keeps the version says nothing.
update public.data_versions set updated_at = now() where key = 'spots';
select is((select count(*)::int from realtime.messages
  where topic = 'data_versions' and payload->>'key' = 'spots'), 0, 'an unchanged version is not broadcast');
-- The source tables still bump through the existing triggers, which now broadcast too.
update public.city_rules_data set version = version where city = '臺北市' and vehicle = 'scooter';
select ok((select count(*) from realtime.messages
  where topic = 'data_versions' and payload->>'key' = 'rules') >= 2, 'a rules edit reaches the topic');

select ok(not has_function_privilege('anon', 'private.broadcast_data_version()', 'execute'),
  'clients cannot call the broadcaster');

select * from finish();
rollback;
