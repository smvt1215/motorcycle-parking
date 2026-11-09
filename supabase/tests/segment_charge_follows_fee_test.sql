-- A segment's condition.charge follows the rates a suggestion changes
-- (202611091000_segment_charge_follows_fee.sql, #369).
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;

-- ===== charge_of_fee()：與 chargeOfFee() 相同 =====
select is(charge_of_fee('{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}'),'free','both free');
select is(charge_of_fee('{"scooter":{"mode":"hourly","amount":20,"per_minutes":60},"heavy":{"mode":"per_visit","amount":30}}'),'toll','both toll');
select is(charge_of_fee('{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":60}}'),null,'vehicles that differ say nothing');
select is(charge_of_fee('{"scooter":{"mode":"free"},"heavy":{"mode":"not_applicable"}}'),'free','a vehicle that cannot park does not count');
select is(charge_of_fee('{"scooter":{"mode":"hourly","amount":20,"per_minutes":60},"heavy":{"mode":"same_as_scooter"}}'),'toll','a follow reads the rate it follows');
select is(charge_of_fee('{"scooter":{"mode":"free"},"heavy":{"mode":"same_as_car"},"car":{"mode":"hourly","amount":40,"per_minutes":60}}'),null,'a follow of the car can differ');
select is(charge_of_fee('{"scooter":{"mode":"by_time","periods":[{"days":"all","rate":{"mode":"free"}},{"days":"weekday","rate":{"mode":"per_visit","amount":20}}]}}'),'toll','a rate by time is toll if any period is');
select is(charge_of_fee('{"scooter":{"mode":"by_time","periods":[{"days":"all","rate":{"mode":"free"}}]}}'),'free','and free if every period is');
select is(charge_of_fee('{}'),null,'no rates, no charge');
select is(charge_of_fee(null),null,'nor without a fee');

-- ===== segments_charge_follow_fee() =====
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}},
    {"id":"b","condition":{"bay":"motorcycle","charge":"toll"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',null)->0->'condition',
  '{"bay":"motorcycle","charge":"free"}'::jsonb,'the named segment follows');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"}},
    {"id":"b","condition":{"bay":"motorcycle","charge":"toll"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',null)->1->'condition'->>'charge',
  'toll','another segment does not');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":60}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":60}}}]',null)->0->'condition',
  '{"bay":"motorcycle"}'::jsonb,'vehicles that differ leave no charge');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"}}]',
  '[{"id":"a","fee":null}]','{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}')->0->'condition'->>'charge',
  'free','back on the road''s rates, it reads those');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}},"condition":{"bay":"motorcycle","charge":"toll"}}]',null)->0->'condition'->>'charge',
  'toll','a condition the patch sends itself stays');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"car","use":"share","share":"car_motorcycle"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',null)->0->'condition' ? 'charge',
  false,'a car bay is not asked');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","limits":[{"kind":"ev_only"}]},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',null)->0->'condition' ? 'charge',
  false,'nor a charging bay');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"charge":"toll"},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',null)->0->'condition'->>'charge',
  'toll','a segment without its own bay reads the spot''s');
select is(segments_charge_follow_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll","basis":{"source_url":"https://x.tw"},"allow":{"scooter":true,"heavy":true}},"fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',
  '[{"id":"a","fee":{"scooter":{"mode":"free"},"heavy":{"mode":"free"}}}]',null)->0->'condition',
  '{"bay":"motorcycle","charge":"free","basis":{"source_url":"https://x.tw"},"allow":{"scooter":true,"heavy":true}}'::jsonb,
  'the rest of the condition stays, its basis too');

-- ===== 經由審核（admin_resolve_report） =====
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,condition,parking_segments)
  values('10000000-0000-4000-8000-000000000001','路段費率測試',25.0701,121.5901,'臺北市','paidMotorcycle',
    '{"bay":"motorcycle","use":"usual","charge":"toll"}',
    '[{"id":"s1","name":"北側","condition":{"bay":"motorcycle","use":"usual","charge":"free","allow":{"scooter":true,"heavy":true}}},
      {"id":"s2","name":"南側","condition":{"bay":"motorcycle","use":"usual","charge":"free","allow":{"scooter":true,"heavy":true}}}]')
  returning id)
  insert into fx select 'street',id from s;
insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='street'),'10000000-0000-4000-8000-000000000002','路段改收費','segments',
    '{"parking_segments":[{"id":"s1","fee":{"scooter":{"mode":"hourly","amount":20,"per_minutes":60},"heavy":{"mode":"hourly","amount":20,"per_minutes":60},"car":{"mode":"not_applicable"}}}]}');
insert into fx select 'report',id from moderation_queue where reason='路段改收費';
set local role authenticated;
select pg_temp.act('admin');
select lives_ok($$select admin_resolve_report((select id from fx where name='report'),'accepted',
  (select jsonb_build_object('parking_segments',proposed->'parking_segments') from moderation_queue where id=(select id from fx where name='report')))$$,
  'a segment''s new rates apply');
reset role;
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='street')),'toll',
  'free turned toll with its rates');
select is((select parking_segments->0->>'name' from community_spots where id=(select id from fx where name='street')),'北側',
  'the rest of the segment stays');
select is((select parking_segments->1->'condition'->>'charge' from community_spots where id=(select id from fx where name='street')),'free',
  'a segment the patch does not name stays');

-- 內部 helper 不開放呼叫。
select ok(not has_function_privilege('anon','public.charge_of_fee(jsonb)','execute'),'charge_of_fee is not an API');
select ok(not has_function_privilege('authenticated','public.segments_charge_follow_fee(jsonb,jsonb,jsonb)','execute'),
  'nor segments_charge_follow_fee');

select * from finish();
rollback;
