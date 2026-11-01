-- 費率與限時層（202611010400_fee_limit_layer.sql，#188 第 2 層）：舊費率轉換、
-- 分區 area 丟掉、路段只限路邊與路段計費規則、點位層資格由條目彙總。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- ===== fee_upgrade() =====
select is(fee_upgrade('{"scooter":{"mode":"daily","amount":30}}'),
  '{"scooter":{"mode":"per_visit","amount":30,"renew":"midnight"}}'::jsonb,'daily becomes per visit, renewed at midnight');
select is(fee_upgrade('{"scooter":{"mode":"daily","amount":30,"cap_reset":"per_entry"}}'),
  '{"scooter":{"mode":"per_visit","amount":30,"renew":"none"}}'::jsonb,'a per-entry daily charge is charged once');
select is(fee_upgrade('{"scooter":{"mode":"daily","amount":30,"cap_reset":"rolling_24h"}}'),
  '{"scooter":{"mode":"per_visit","amount":30}}'::jsonb,'a rolling day has no renew to match');
select is(fee_upgrade('{"scooter":{"mode":"posted"},"heavy":{"mode":"free"}}'),
  '{"heavy":{"mode":"free"}}'::jsonb,'posted leaves the vehicle out');
select is(fee_upgrade('{"heavy":{"mode":"per_visit","amount":0,"max_minutes":20,"extension":{"amount":40,"max_times":1}}}'),
  '{"heavy":{"mode":"per_visit","amount":0,"extension_amount":40}}'::jsonb,'max_minutes goes, the extension keeps its amount');
select is(fee_upgrade('{"scooter":{"mode":"hourly","amount":10,"per_minutes":60,"free_minutes":30,"unit_minutes":30}}'),
  '{"scooter":{"mode":"hourly","amount":10,"per_minutes":60}}'::jsonb,'free and unit minutes go');
select is(fee_upgrade('{"scooter":{"mode":"hourly","amount":10,"per_minutes":60},"heavy":{"mode":"same_as_scooter","factor_pct":200}}'),
  '{"scooter":{"mode":"hourly","amount":10,"per_minutes":60},"heavy":{"mode":"hourly","amount":20,"per_minutes":60}}'::jsonb,
  'a factor other than 100 becomes the rate worked out');
select is(fee_upgrade('{"car":{"mode":"by_time","periods":[{"days":"all","rate":{"mode":"posted"}}]}}'),'{}'::jsonb,
  'a by_time of posted periods only leaves the vehicle out');
select ok(valid_fee(fee_upgrade('{"scooter":{"mode":"per_visit","amount":30,"max_minutes":360},"heavy":{"mode":"daily","amount":50}}')),
  'what it returns is a valid fee');
select is(fee_plans_upgrade('[{"id":"p1","name":"公告","fee":{"scooter":{"mode":"posted"}}},{"id":"p2","name":"每日","fee":{"scooter":{"mode":"daily","amount":5}}}]'),
  '[{"id":"p2","name":"每日","fee":{"scooter":{"mode":"per_visit","amount":5,"renew":"midnight"}}}]'::jsonb,
  'a plan left empty goes');
select is(fee_plans_emptied('[{"id":"p1","name":"公告","fee":{"scooter":{"mode":"posted"}}}]'),array['p1'],'and is named');
select is(entries_upgrade('[{"name":"B1","area":"car","fee_plan":"p1","fee":{"scooter":{"mode":"posted"}}}]',array['p1']),
  '[{"name":"B1","fee":{}}]'::jsonb,'its zones lose the reference and the area');

-- ===== area 丟掉、路段只限路邊 =====
create temporary table fx(name text primary key,id uuid);
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,parking_zones)
  values('10000000-0000-4000-8000-000000000001','分區區域',25.061,121.581,'臺北市','offStreet',
    '[{"name":"B1","area":"motorcycle","access":"scooterOnly"}]') returning id)
  insert into fx select 'lot',id from s;
select ok(not (select parking_zones->0 ? 'area' from community_spots where id=(select id from fx where name='lot')),
  'an old writer''s zone area is dropped, not refused');
select throws_ok($$update community_spots set parking_segments='[{"name":"北側"}]' where id=(select id from fx where name='lot')$$,
  '23514',null,'a lot takes no segments');

-- ===== 路段費率與計費規則 =====
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,fee_plans,parking_segments)
  values('10000000-0000-4000-8000-000000000001','路段費率',25.062,121.582,'臺北市','paidMotorcycle',true,false,
    '[{"id":"p1","name":"路邊計時","fee":{"scooter":{"mode":"hourly","amount":20,"per_minutes":60}}}]',
    '[{"name":"北側","fee_plan":"p1","fee":{"scooter":{"mode":"free"}}},{"name":"南側","fee":{"scooter":{"mode":"free"}}}]')
  returning id)
  insert into fx select 'street',id from s;
select is((select parking_segments->0->'fee' from community_spots where id=(select id from fx where name='street')),
  '{"scooter":{"mode":"hourly","amount":20,"per_minutes":60}}'::jsonb,'a segment referring to a plan carries its fee');
select is((select parking_segments->1->'fee' from community_spots where id=(select id from fx where name='street')),
  '{"scooter":{"mode":"free"}}'::jsonb,'a segment keeps its own fee');
update community_spots set fee_plans=jsonb_set(fee_plans,'{0,fee,scooter,amount}','30')
  where id=(select id from fx where name='street');
select is((select parking_segments->0->'fee'->'scooter'->>'amount' from community_spots where id=(select id from fx where name='street')),
  '30','an edited plan reaches its segments');
create temporary table caught(detail jsonb);
do $$ begin
  update community_spots set fee_plans=null where id=(select id from fx where name='street');
exception when foreign_key_violation then
  declare d text; begin get stacked diagnostics d=pg_exception_detail; insert into caught values(d::jsonb); end;
end $$;
select is((select detail->'plans'->0->>'segments' from caught),'1','removing a plan a segment uses is refused, with the count');

-- ===== 資格跟格位走 =====
update community_spots set parking_segments='[{"name":"北側","condition":{"allow":{"scooter":true,"heavy":true}}},
  {"name":"南側","condition":{"allow":{"scooter":false,"heavy":"not_stated"}}}]'
  where id=(select id from fx where name='street');
select is((select array[scooter_allowed::text,heavy_allowed::text,heavy_not_stated::text] from community_spots
  where id=(select id from fx where name='street')),array['true','true','false'],'any segment that lets a vehicle park opens it');
update community_spots set parking_segments='[{"name":"南側","condition":{"allow":{"scooter":false,"heavy":"not_stated"}}}]'
  where id=(select id from fx where name='street');
select is((select array[scooter_allowed::text,coalesce(heavy_allowed::text,'null'),heavy_not_stated::text] from community_spots
  where id=(select id from fx where name='street')),array['false','null','true'],'every segment stating it: not_stated, else false');
select throws_ok($$update community_spots set scooter_allowed=true where id=(select id from fx where name='street')$$,
  '22023','eligibility follows the bays','a flag the segments decide is not changed alone');
update community_spots set parking_segments='[{"name":"南側"}]',scooter_allowed=true
  where id=(select id from fx where name='street');
select is((select scooter_allowed from community_spots where id=(select id from fx where name='street')),true,
  'a segment that says nothing leaves the spot''s own flags');
-- An incomplete lot: zones only open, never close.
update community_spots set parking_zones='[{"name":"B1","access":"noMotorcycle"}]',scooter_allowed=true
  where id=(select id from fx where name='lot');
select is((select scooter_allowed from community_spots where id=(select id from fx where name='lot')),true,
  'a lot whose zones may be partial keeps its flags');
update community_spots set zones_complete=true where id=(select id from fx where name='lot');
select is((select scooter_allowed from community_spots where id=(select id from fx where name='lot')),false,
  'a complete one is what its zones say');

select * from finish();
rollback;
