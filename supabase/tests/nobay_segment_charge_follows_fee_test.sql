-- A segment without its own bay: its charge follows its rates when the
-- spot's condition is a 一般機車格 or 普大共用格
-- (202611111700_nobay_segment_charge_follows_fee.sql, #399 rule A).
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
  ('mixed','{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":60},"car":{"mode":"not_applicable"}}');
create function pg_temp.fee(n text) returns jsonb language sql as $$ select fee from fees where name=n $$;
-- One segment, the same before and after, under a road fee from p_from to p_to.
create function pg_temp.road(seg jsonb,p_from text,p_to text,whole jsonb) returns jsonb language sql as $$
  select public.segments_charge_follow_spot_fee(jsonb_build_array(seg),jsonb_build_array(seg),
    pg_temp.fee(p_from),pg_temp.fee(p_to),whole)->0 $$;

-- ===== spot_whole_condition()：與 spot.condition ?? conditionOf(spaceType) 相同 =====
select is(spot_whole_condition('{"bay":"car","use":"usual"}','paidMotorcycle'),'{"bay":"car","use":"usual"}'::jsonb,
  'the spot''s own condition first');
select is(spot_whole_condition(null,'paidMotorcycle'),'{"bay":"motorcycle","use":"usual","charge":"toll"}'::jsonb,
  'else the one its space type stands for');
select is(spot_whole_condition(null,'offStreet'),null,'a lot stands for none');

-- ===== segments_charge_follow_spot_fee()：沒寫 bay 的路段 =====
select is(pg_temp.road('{"id":"a","condition":{"charge":"free","allow":{"scooter":true}}}','free','toll',
    '{"bay":"motorcycle","use":"usual","charge":"free"}')->'condition',
  '{"charge":"toll","allow":{"scooter":true}}'::jsonb,'on a 一般機車格 it follows the road''s new rates');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free","allow":{"scooter":true}}}','free','mixed',
    '{"bay":"motorcycle","use":"usual","charge":"free"}')->'condition',
  '{"allow":{"scooter":true}}'::jsonb,'rates that say neither take the charge away, so the spot''s is read');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free"}}','free','mixed',
    '{"bay":"motorcycle","use":"usual","charge":"free"}'),
  '{"id":"a"}'::jsonb,'a condition left empty goes, as an empty one is not valid');
select is(pg_temp.road('{"id":"a","condition":{"charge":"toll"}}','free','toll',
    '{"bay":"motorcycle","use":"share","share":"scooter_heavy","charge":"free"}')->'condition'->>'charge',
  'toll','a 普大共用格 is asked too');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free"}}','free','toll',spot_whole_condition(null,'paidMotorcycle'))->'condition'->>'charge',
  'toll','a spot without its own condition reads its space type''s');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free"}}','free','toll',null)->'condition'->>'charge',
  'free','a spot whose condition is unknown leaves it');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free"}}','free','toll',
    '{"bay":"car","use":"share","share":"car_motorcycle"}')->'condition'->>'charge',
  'free','a car bay is not asked');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free"}}','free','toll',
    '{"bay":"motorcycle","limits":[{"kind":"ev_only"}]}')->'condition'->>'charge',
  'free','nor a charging bay');
select is(pg_temp.road('{"id":"a","condition":{"charge":"free","limits":[{"kind":"special_vehicle","vehicle":"disabled_modified"}]}}','free','toll',
    '{"bay":"motorcycle","use":"usual","charge":"free"}')->'condition'->>'charge',
  'free','nor a segment whose own limit makes it a 身障格');
select is(pg_temp.road('{"id":"a","name":"北側"}','free','toll','{"bay":"motorcycle","use":"usual","charge":"free"}'),
  '{"id":"a","name":"北側"}'::jsonb,'a segment without a condition is left to the spot''s');
-- Rates of its own, other than the road's.
select is(pg_temp.road(jsonb_build_object('id','a','fee',pg_temp.fee('free'),'condition','{"charge":"free"}'::jsonb),'toll','mixed',
    '{"bay":"motorcycle","use":"usual","charge":"toll"}')->'condition'->>'charge',
  'free','its own rates unchanged, a new road fee changes nothing');
select is(public.segments_charge_follow_spot_fee(
    jsonb_build_array(jsonb_build_object('id','a','fee',pg_temp.fee('free'),'condition','{"charge":"free"}'::jsonb)),
    jsonb_build_array(jsonb_build_object('id','a','fee',pg_temp.fee('toll'),'condition','{"charge":"free"}'::jsonb)),
    pg_temp.fee('free'),pg_temp.fee('free'),'{"bay":"motorcycle","use":"usual","charge":"free"}')->0->'condition'->>'charge',
  'toll','its own new rates count, not the road''s');

-- ===== #369 的審核步驟不變 =====
select is(segment_charge_of('{"id":"a","condition":{"charge":"toll"}}',pg_temp.fee('free')),
  '{"id":"a","condition":{"charge":"toll"}}'::jsonb,'segment_charge_of() without the spot''s condition leaves it');

-- ===== 經由管理站與審核 =====
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated;
-- A street spot stored without a condition (its space type says 收費機車格),
-- with s1 (no bay, rates of the road) and s2 (no bay, rates of its own).
create function pg_temp.street(n text,t text) returns void language sql as $$
  with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,fee,fee_note,parking_segments)
    values('10000000-0000-4000-8000-000000000001',n,25.0703,121.5903,'臺北市','paidMotorcycle',
      pg_temp.fee('toll'),fee_note_of(pg_temp.fee('toll')),
      jsonb_build_array(
        '{"id":"s1","name":"北側","condition":{"charge":"toll","allow":{"scooter":true,"heavy":true}}}'::jsonb,
        jsonb_build_object('id','s2','name','南側','fee',pg_temp.fee('free'),
          'condition','{"charge":"free","allow":{"scooter":true,"heavy":true}}'::jsonb)))
    returning id)
  insert into fx select t,id from s;
$$;
select pg_temp.street('沒寫 bay 的路段編輯','edit');
select pg_temp.street('沒寫 bay 的路段審核','review');

create temporary table edit as select
  jsonb_build_object('fee',pg_temp.fee('mixed'),'fee_note',fee_note_of(pg_temp.fee('mixed'))) v,
  c.updated_at at from community_spots c where c.id=(select id from fx where name='edit');
grant select on edit to authenticated;
set local role authenticated;
select pg_temp.act('admin');
select lives_ok($$select admin_upsert_spot((select id::text from fx where name='edit'),(select v from edit),(select at from edit))$$,
  'an admin edits the road''s rates');
reset role;
select is((select parking_segments->0->'condition' from community_spots where id=(select id from fx where name='edit')),
  '{"allow":{"scooter":true,"heavy":true}}'::jsonb,'rates that say neither leave the segment no charge of its own');
select is((select parking_segments->1->'condition'->>'charge' from community_spots where id=(select id from fx where name='edit')),'free',
  'the segment with rates of its own keeps its charge');

-- A rider's {id, fee} on the segment with its own rates.
insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='review'),'10000000-0000-4000-8000-000000000002','沒寫 bay 的路段改收費','segments',
    jsonb_build_object('parking_segments',jsonb_build_array(jsonb_build_object('id','s2','fee',pg_temp.fee('toll')))));
insert into fx select 'report',id from moderation_queue where reason='沒寫 bay 的路段改收費';
set local role authenticated;
select pg_temp.act('admin');
select lives_ok($$select admin_resolve_report((select id from fx where name='report'),'accepted',
  (select jsonb_build_object('parking_segments',proposed->'parking_segments') from moderation_queue where id=(select id from fx where name='report')))$$,
  'the segment''s new rates apply');
reset role;
select is((select parking_segments->1->'condition'->>'charge' from community_spots where id=(select id from fx where name='review')),'toll',
  'free turned toll with its own rates');
select is((select parking_segments->0->'condition'->>'charge' from community_spots where id=(select id from fx where name='review')),'toll',
  'the other segment stays');

select * from finish();
rollback;
