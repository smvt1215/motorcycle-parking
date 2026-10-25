begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'admin_aal1' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;

-- fee_note_of writes what feeNoteOf in lib/models/fee.dart writes
-- (test/fee_test.dart pins the same sentences).
select is(fee_note_of('{}'),'請依現場公告','no vehicle known');
select is(fee_note_of('{"scooter":{"mode":"daily","amount":30},"heavy":{"mode":"same_as_scooter"}}'),
  '每日 30 元（大型重機比照機車費率）','heavy bikes follow scooters');
select is(fee_note_of('{"scooter":{"mode":"free"},"heavy":{"mode":"hourly","amount":20,"per_minutes":60,"daily_cap":100}}'),
  '機車免費；大型重機每小時 20 元，當日上限 100 元','separate rates');
select is(fee_note_of('{"scooter":{"mode":"hourly","amount":10,"per_minutes":30}}'),
  '每 30 分鐘 10 元（大型重機費率未確認）','only the scooter rate');
select is(fee_note_of('{"scooter":{"mode":"hourly","amount":40,"per_minutes":120}}'),
  '每 2 小時 40 元（大型重機費率未確認）','periods in whole hours');
select is(fee_note_of('{"heavy":{"mode":"per_visit","amount":50,"max_minutes":90}}'),
  '大型重機每次 50 元（90 分鐘內）','only the heavy rate, a limit in minutes');
select is(fee_note_of('{"scooter":{"mode":"per_visit","amount":20,"max_minutes":360},"heavy":{"mode":"same_as_car"}}'),
  '每次 20 元（6 小時內）（大型重機比照汽車費率）','per visit with a limit in hours');
select is(fee_note_of('{"scooter":{"mode":"posted"},"heavy":{"mode":"posted"}}'),
  '機車依現場公告；大型重機依現場公告','posted rates');

create temporary table fx(name text primary key,id uuid,at timestamptz);
grant select,update on fx to authenticated;
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,scooter_allowed,fee_note)
  values('10000000-0000-4000-8000-000000000001','費率表單社群點',25.051,121.571,'臺北市','松山區','paidMotorcycle',true,'每小時20元') returning id,updated_at)
  insert into fx select 'community',id,updated_at from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date,heavy_allowed)
  values('費率表單官方點',25.052,121.572,'臺北市','https://example.test/notice','臺北市政府',current_date,true) returning id,updated_at)
  insert into fx select 'official',id,updated_at from s;

select ok('fee'=any(admin_spot_fields(false)),'community spots list fee as editable');
select ok('fee'=any(admin_spot_fields(true)),'official spots list fee as editable');

-- Only an admin with a second factor.
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":{"scooter":{"mode":"free"}},"fee_note":"免費（大型重機費率未確認）"}',(select at from fx where name='community'))$$,
  '42501',null,'an ordinary user cannot set a fee');
reset role;
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":{"scooter":{"mode":"free"}},"fee_note":"免費（大型重機費率未確認）"}',(select at from fx where name='community'))$$,
  '42501',null,'an admin without a second factor cannot set a fee');
reset role;

select pg_temp.act('admin');
set local role authenticated;
-- Invalid fees are refused before the table check.
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":{"scooter":{"mode":"hourly","amount":20}},"fee_note":"每小時 20 元（大型重機費率未確認）"}',(select at from fx where name='community'))$$,
  '22023','invalid fee','an hourly rate without its period is refused');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":{"scooter":{"mode":"same_as_car"}}}',(select at from fx where name='community'))$$,
  '22023','invalid fee','scooters cannot follow another vehicle');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":"免費"}',(select at from fx where name='community'))$$,
  '22023','invalid fee','a fee is an object');
-- The text must be the fee's own.
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":{"scooter":{"mode":"daily","amount":30}},"fee_note":"每日 30 元"}',(select at from fx where name='community'))$$,
  '22023','fee_note must be the text of fee','a fee with other text is refused');
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee":{"scooter":{"mode":"daily","amount":30}}}',(select at from fx where name='community'))$$,
  '22023','fee_note must be the text of fee','a fee without its text keeps the stale legacy text, so it is refused');

-- An admin writes a fee with its text.
select is(admin_upsert_spot((select id::text from fx where name='community'),
    '{"fee":{"scooter":{"mode":"hourly","amount":20,"per_minutes":60},"heavy":{"mode":"same_as_scooter"}},"fee_note":"每小時 20 元（大型重機比照機車費率）"}',
    (select at from fx where name='community'),'依現場公告牌')->'fee'->'scooter'->>'amount',
  '20','an admin sets a community fee');
update fx set at=(select updated_at from community_spots where id=fx.id) where name='community';
-- With a fee in place, its text follows it.
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='community'),
  '{"fee_note":"每小時 30 元"}',(select at from fx where name='community'))$$,
  '22023','fee_note must be the text of fee','text alone cannot drift from the stored fee');
select is(admin_upsert_spot((select id::text from fx where name='community'),'{"note":"入口在後方"}',(select at from fx where name='community'))->>'note',
  '入口在後方','other edits pass while the fee stays');
update fx set at=(select updated_at from community_spots where id=fx.id) where name='community';
-- Clearing the fee frees the text again.
select is(admin_upsert_spot((select id::text from fx where name='community'),
    '{"fee":null,"fee_note":"請依現場公告"}',(select at from fx where name='community'))->'fee',
  'null'::jsonb,'an admin clears the fee');
reset role;
select is((select fee_note from community_spots where id=(select id from fx where name='community')),'請依現場公告','the text changed with it');
select is((select count(*)::integer from community_spots where id=(select id from fx where name='community')
  and scooter_allowed and scooter_verified_at is null),1,'a fee edit verifies no vehicle');

-- Official spots.
select pg_temp.act('admin');
set local role authenticated;
select is(admin_upsert_spot('official:'||(select id from fx where name='official'),
    '{"fee":{"heavy":{"mode":"free"}},"fee_note":"大型重機免費"}',(select at from fx where name='official'))->'fee',
  '{"heavy":{"mode":"free"}}'::jsonb,'an admin sets an official fee');
select throws_ok($$select admin_upsert_spot(null,'{"kind":"official","name":"新官方費率點","lat":25.06,"lng":121.58,"city":"臺北市","space_type":"heavyOnly","source_name":"臺北市政府","source_url":"https://example.test","effective_date":"2026-10-25","fee":{"heavy":{"mode":"daily","amount":50}}}')$$,
  '22023','fee_note must be the text of fee','a new spot with a fee needs its text, not the default');
select is(admin_upsert_spot(null,'{"kind":"community","name":"新社群費率點","lat":25.061,"lng":121.581,"city":"臺北市","space_type":"paidMotorcycle","fee":{"scooter":{"mode":"per_visit","amount":20}},"fee_note":"每次 20 元（大型重機費率未確認）"}')->'fee'->'scooter'->>'mode',
  'per_visit','an admin creates a spot with a fee');
reset role;

-- Audited with the fee before and after.
select is((select before->'fee' from admin_audit_log where action='update_spot' and note='依現場公告牌'),'null'::jsonb,'the audit keeps the fee before');
select is((select after->'fee'->'heavy'->>'mode' from admin_audit_log where action='update_spot' and note='依現場公告牌'),'same_as_scooter','and after');
select is((select after->>'fee_note' from admin_audit_log where action='update_spot' and note='依現場公告牌'),'每小時 20 元（大型重機比照機車費率）','with its text');
select is((select after->'fee' from admin_audit_log where action='update_spot' and target_table='official_heavy_spots'),
  '{"heavy":{"mode":"free"}}'::jsonb,'official fee edits are audited');

-- Restating vehicle access still verifies it alongside a fee edit.
update fx set at=(select updated_at from community_spots where id=fx.id) where name='community';
select pg_temp.act('admin');
set local role authenticated;
select ok(admin_upsert_spot((select id::text from fx where name='community'),
    '{"scooter_allowed":true,"fee":{"scooter":{"mode":"free"}},"fee_note":"免費（大型重機費率未確認）"}',(select at from fx where name='community')) is not null,
  'a fee with a restated vehicle flag');
reset role;
select ok((select scooter_verified_at is not null from community_spots where id=(select id from fx where name='community')),
  'the restated flag is verified');
select is(current_setting('app.admin_vehicle_fields',true),'','the stated fields are cleared after the call');

-- Adopting a report keeps the same rule.
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,scooter_allowed,fee,fee_note)
  values('10000000-0000-4000-8000-000000000001','審核費率點',25.053,121.573,'臺北市','松山區','paidMotorcycle',true,
    '{"scooter":{"mode":"daily","amount":30}}','每日 30 元（大型重機費率未確認）') returning id,updated_at)
  insert into fx select 'reviewed',id,updated_at from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note)
  values('10000000-0000-4000-8000-000000000001','審核舊文字點',25.054,121.574,'臺北市','松山區','paidMotorcycle','每小時20元') returning id,updated_at)
  insert into fx select 'legacy',id,updated_at from s;
insert into moderation_queue(source_id,reason,field,proposed) values
  ((select id::text from fx where name='reviewed'),'收費資訊：每次 30 元','fee_note','{"fee_note":"每次 30 元"}'),
  ((select id::text from fx where name='reviewed'),'收費資訊：不一致','fee_note','{"fee":{"scooter":{"mode":"free"}},"fee_note":"免費"}'),
  ((select id::text from fx where name='reviewed'),'收費資訊：一致','fee_note',
    '{"fee":{"scooter":{"mode":"free"}},"fee_note":"免費（大型重機費率未確認）","scooter_allowed":true}'),
  ((select id::text from fx where name='legacy'),'收費資訊：舊文字','fee_note','{"fee_note":"每次 15 元"}');
create temporary table q as select id,reason from moderation_queue where reason like '收費資訊：%' and source_id in
  (select id::text from fx where name in ('reviewed','legacy'));
grant select on q to authenticated;
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from q where reason='收費資訊：一致'),'accepted',
  (select proposed from moderation_queue where id=(select id from q where reason='收費資訊：一致')))$$,
  '42501',null,'an ordinary user cannot adopt a fee');
reset role;
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from q where reason='收費資訊：每次 30 元'),'accepted','{"fee_note":"每次 30 元"}')$$,
  '22023','fee_note must be the text of fee','a text-only suggestion cannot drift from a stored fee');
select throws_ok($$select admin_resolve_report((select id from q where reason='收費資訊：不一致'),'accepted',
  '{"fee":{"scooter":{"mode":"free"}},"fee_note":"免費"}')$$,
  '22023','fee_note must be the text of fee','a fee adopted with other text is refused');
select throws_ok($$select admin_resolve_report((select id from q where reason='收費資訊：不一致'),'accepted',
  '{"fee":{"scooter":{"mode":"free"}}}')$$,
  '22023','fee_note must be the text of fee','a fee adopted without its text is refused');
select is(admin_resolve_report((select id from q where reason='收費資訊：一致'),'accepted',
    (select proposed from moderation_queue where id=(select id from q where reason='收費資訊：一致')),'比對公告')->'spot'->>'fee_note',
  '免費（大型重機費率未確認）','a fee adopted with its own text');
-- Sent before the fee above was adopted: forced once the admin has seen it.
select is(admin_resolve_report((select id from q where reason='收費資訊：每次 30 元'),'accepted','{"fee":null,"fee_note":"每次 30 元"}','',true)->'spot'->'fee',
  'null'::jsonb,'clearing the fee frees the text');
select is(admin_resolve_report((select id from q where reason='收費資訊：舊文字'),'accepted','{"fee_note":"每次 15 元"}')->'spot'->>'fee_note',
  '每次 15 元','a spot without a fee takes text as before');
reset role;
select is((select status from moderation_queue where id=(select id from q where reason='收費資訊：不一致')),'pending',
  'a refused adoption leaves the report pending');
select ok((select scooter_verified_at is not null from community_spots where id=(select id from fx where name='reviewed')),
  'a restated flag adopted with a fee is still verified');
select is((select after->'spot'->'fee' from admin_audit_log where action='resolve_report' and note='比對公告'),
  '{"scooter":{"mode":"free"}}'::jsonb,'the audit keeps the adopted fee');
select is((select before->'spot'->'fee' from admin_audit_log where action='resolve_report' and note='比對公告'),
  '{"scooter":{"mode":"daily","amount":30}}'::jsonb,'and the fee before');
-- A stale report is still reported as a conflict, not as a fee problem.
insert into moderation_queue(source_id,reason,field,proposed) values
  ((select id::text from fx where name='reviewed'),'收費資訊：舊版本','fee_note','{"fee_note":"免費"}');
update community_spots set fee='{"scooter":{"mode":"daily","amount":40}}',fee_note='每日 40 元（大型重機費率未確認）'
  where id=(select id from fx where name='reviewed');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from moderation_queue where reason='收費資訊：舊版本'),'accepted','{"fee_note":"免費"}')$$,
  '40001',null,'version conflicts come first');
select throws_ok($$select admin_resolve_report((select id from moderation_queue where reason='收費資訊：舊版本'),'accepted','{"fee_note":"免費"}','',true)$$,
  '22023','fee_note must be the text of fee','forcing does not skip the fee rule');
reset role;

select * from finish();
rollback;
