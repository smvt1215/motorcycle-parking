-- A segment's condition.charge follows the rates it actually pays, whichever
-- write changes them (202611111000_segment_charge_follows_spot_fee.sql, #399).
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

create temporary table fees(name text primary key,fee jsonb);
grant select on fees to authenticated;
insert into fees values
  ('free','{"scooter":{"mode":"free"},"heavy":{"mode":"free"},"car":{"mode":"not_applicable"}}'),
  ('toll','{"scooter":{"mode":"hourly","amount":20,"per_minutes":60},"heavy":{"mode":"hourly","amount":20,"per_minutes":60},"car":{"mode":"not_applicable"}}'),
  ('mixed','{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":60},"car":{"mode":"not_applicable"}}'),
  ('visit','{"scooter":{"mode":"per_visit","amount":30},"heavy":{"mode":"per_visit","amount":30},"car":{"mode":"not_applicable"}}');
create function pg_temp.fee(n text) returns jsonb language sql as $$ select fee from fees where name=n $$;

-- ===== segment_fee_of() =====
select is(segment_fee_of('{"fee":{"scooter":{"mode":"free"}}}','{"scooter":{"mode":"daily","amount":50}}'),
  '{"scooter":{"mode":"free"}}'::jsonb,'a segment''s own rates first');
select is(segment_fee_of('{"fee":{}}','{"scooter":{"mode":"free"}}'),'{"scooter":{"mode":"free"}}'::jsonb,
  'empty rates read the road''s');
select is(segment_fee_of('{"fee":null}',null),null,'and neither is none');

-- ===== segments_charge_follow_spot_fee() =====
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","name":"北","condition":{"bay":"motorcycle","charge":"free"}}]',
  '[{"id":"a","name":"北","condition":{"bay":"motorcycle","charge":"free"}}]',pg_temp.fee('free'),pg_temp.fee('toll'))->0->'condition',
  '{"bay":"motorcycle","charge":"toll"}'::jsonb,'a segment on the road''s rates follows a new road fee');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"},"fee":{"scooter":{"mode":"free"}}}]',
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"},"fee":{"scooter":{"mode":"free"}}}]',pg_temp.fee('free'),pg_temp.fee('toll'))->0->'condition'->>'charge',
  'free','one with its own rates does not');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"}}]',
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"}}]',pg_temp.fee('free'),pg_temp.fee('mixed'))->0->'condition',
  '{"bay":"motorcycle"}'::jsonb,'vehicles that differ leave no charge');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"}}]',
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"}}]',pg_temp.fee('free'),null)->0->'condition',
  '{"bay":"motorcycle"}'::jsonb,'nor do rates taken away');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"},"fee":{"scooter":{"mode":"hourly","amount":20,"per_minutes":60}}}]',
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"},"fee":{"scooter":{"mode":"free"}}}]',null,null)->0->'condition'->>'charge',
  'free','a segment''s own new rates count too');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free"}}]',
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free","limits":[{"kind":"time_limit"}]}}]',pg_temp.fee('free'),pg_temp.fee('toll'))->0->'condition'->>'charge',
  'free','a write that changes the condition itself is the writer''s');
select is(segments_charge_follow_spot_fee(
  '[]','[{"id":"a","condition":{"bay":"motorcycle","charge":"free"}}]',pg_temp.fee('free'),pg_temp.fee('toll'))->0->'condition'->>'charge',
  'free','a new segment keeps what it was given');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"}}]',
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"toll"}}]',pg_temp.fee('free'),pg_temp.fee('free'))->0->'condition'->>'charge',
  'toll','rates that did not change are not read');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"charge":"free"}}]',
  '[{"id":"a","condition":{"charge":"free"}}]',pg_temp.fee('free'),pg_temp.fee('toll'))->0->'condition'->>'charge',
  'free','a segment without its own bay is left to the spot (#399, to be decided)');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"car","use":"share","share":"car_motorcycle"}}]',
  '[{"id":"a","condition":{"bay":"car","use":"share","share":"car_motorcycle"}}]',pg_temp.fee('free'),pg_temp.fee('toll'))->0->'condition' ? 'charge',
  false,'a car bay is not asked');
select is(segments_charge_follow_spot_fee(
  '[{"id":"a","condition":{"bay":"motorcycle","charge":"free","basis":{"source_url":"https://x.tw"}}},{"id":"b","condition":{"bay":"motorcycle","charge":"free"}}]',
  '[{"id":"b","condition":{"bay":"motorcycle","charge":"free"}},{"id":"a","condition":{"bay":"motorcycle","charge":"free","basis":{"source_url":"https://x.tw"}}}]',
  pg_temp.fee('free'),pg_temp.fee('toll')),
  '[{"id":"b","condition":{"bay":"motorcycle","charge":"toll"}},{"id":"a","condition":{"bay":"motorcycle","charge":"toll","basis":{"source_url":"https://x.tw"}}}]'::jsonb,
  'segments match by id, keep their order and the rest of the condition');

-- ===== Fixtures =====
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated;
-- A free road: two segments on its rates (s1, and s2 without its own bay)
-- and one with rates of its own (s3, per visit).
create function pg_temp.street(n text,t text) returns void language sql as $$
  with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,condition,fee,fee_note,parking_segments)
    values('10000000-0000-4000-8000-000000000001',n,25.0702,121.5902,'臺北市','freeMotorcycle',
      '{"bay":"motorcycle","use":"usual","charge":"free"}',pg_temp.fee('free'),fee_note_of(pg_temp.fee('free')),
      jsonb_build_array(
        '{"id":"s1","name":"北側","condition":{"bay":"motorcycle","use":"usual","charge":"free","allow":{"scooter":true,"heavy":true}}}'::jsonb,
        '{"id":"s2","name":"南側","condition":{"charge":"free","allow":{"scooter":true,"heavy":true}}}'::jsonb,
        jsonb_build_object('id','s3','name','東側','fee',pg_temp.fee('visit'),
          'condition','{"bay":"motorcycle","use":"usual","charge":"toll","allow":{"scooter":true,"heavy":true}}'::jsonb)))
    returning id)
  insert into fx select t,id from s;
$$;
select pg_temp.street('整條路費率審核','review');
select pg_temp.street('整條路費率編輯','edit');
select pg_temp.street('整條路費率與條件','both');

-- ===== 1. 審核整條路的費率（admin_resolve_report 的頂層 fee） =====
insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='review'),'10000000-0000-4000-8000-000000000002','整條路改收費','fee',
    jsonb_build_object('fee',pg_temp.fee('toll')));
insert into fx select 'report',id from moderation_queue where reason='整條路改收費';
create temporary table patch as select jsonb_build_object('fee',pg_temp.fee('toll'),'fee_note',fee_note_of(pg_temp.fee('toll'))) p;
grant select on patch to authenticated;
set local role authenticated;
select pg_temp.act('admin');
select lives_ok($$select admin_resolve_report((select id from fx where name='report'),'accepted',(select p from patch))$$,
  'the road''s new rates apply');
reset role;
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='review')),'toll',
  'a segment on the road''s rates turned toll');
select is((select parking_segments->1->'condition'->>'charge' from community_spots where id=(select id from fx where name='review')),'free',
  'a segment without its own bay is not touched');
select is((select parking_segments->2->'condition'->>'charge' from community_spots where id=(select id from fx where name='review')),'toll',
  'one with its own rates keeps them');

-- ===== 4. 管理站直接編輯（admin_upsert_spot） =====
create temporary table edit as select
  jsonb_build_object('fee',pg_temp.fee('toll'),'fee_note',fee_note_of(pg_temp.fee('toll')),'parking_segments',c.parking_segments) v,
  c.updated_at at,c.parking_segments segs from community_spots c where c.id=(select id from fx where name='edit');
grant select on edit to authenticated;
set local role authenticated;
select pg_temp.act('admin');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='edit'),(select v from edit),(select at from edit))$$,
  'an admin edits the road''s rates, sending the segments as they were');
reset role;
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='edit')),'toll',
  'the segment on the road''s rates follows');
select is((select parking_segments->2->'condition'->>'charge' from community_spots where id=(select id from fx where name='edit')),'toll',
  'the one with its own rates does not');

-- The admin's own condition wins when the same edit changes it.
create temporary table both_edit as select
  jsonb_build_object('fee',pg_temp.fee('toll'),'fee_note',fee_note_of(pg_temp.fee('toll')),
    'parking_segments',jsonb_set(c.parking_segments,'{0,condition,basis}','{"source_url":"https://example.test/notice"}')) v,
  c.updated_at at from community_spots c where c.id=(select id from fx where name='both');
grant select on both_edit to authenticated;
set local role authenticated;
select pg_temp.act('admin');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='both'),(select v from both_edit),(select at from both_edit))$$,
  'an admin edits the rates and a segment''s condition together');
reset role;
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='both')),'free',
  'the condition the admin wrote stays as written');

-- ===== Any other update: the trigger itself =====
update community_spots set fee=pg_temp.fee('free'),fee_note=fee_note_of(pg_temp.fee('free'))
  where id=(select id from fx where name='edit');
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='edit')),'free',
  'back to free, back to free');
update community_spots set note='入口在後方' where id=(select id from fx where name='edit');
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='edit')),'free',
  'an edit that leaves the rates alone changes nothing');

-- 內部 helper 不開放呼叫。
select ok(not has_function_privilege('authenticated','public.segments_charge_follow_spot_fee(jsonb,jsonb,jsonb,jsonb)','execute'),
  'segments_charge_follow_spot_fee is not an API');

select * from finish();
rollback;
