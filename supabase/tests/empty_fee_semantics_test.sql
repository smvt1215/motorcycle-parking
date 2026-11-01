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

-- A stored fee {} names no vehicle: like no fee, its text is free (#114),
-- as the admin site's storedFee() reads it.
select ok(fee_note_matches('{"fee":{},"fee_note":"每小時 20 元"}'),'fee {} leaves the text free');
select ok(fee_note_matches('{"fee":null,"fee_note":"每小時 20 元"}'),'as a null fee does');
select ok(fee_note_matches('{"fee_note":"每小時 20 元"}'),'and a missing one');
select ok(not fee_note_matches('{"fee":{"scooter":{"mode":"free"}},"fee_note":"每小時 20 元"}'),
  'a fee with a vehicle still needs its own text');
select ok(fee_note_matches('{"fee":{"scooter":{"mode":"free"}},"fee_note":"機車免費；大型重機費率未提供"}'),
  'and takes it');

create temporary table fx(name text primary key,id uuid,at timestamptz);
grant select,update on fx to authenticated;
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,scooter_allowed,fee,fee_note)
  values('10000000-0000-4000-8000-000000000001','空費率社群點',25.071,121.591,'臺北市','松山區','paidMotorcycle',true,'{}','請依現場公告')
  returning id,updated_at)
  insert into fx select 'community',id,updated_at from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date,heavy_allowed,fee,fee_note)
  values('空費率官方點',25.072,121.592,'臺北市','https://example.test/notice','臺北市政府',current_date,true,'{}','請依現場公告')
  returning id,updated_at)
  insert into fx select 'official',id,updated_at from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,scooter_allowed,fee,fee_note)
  values('10000000-0000-4000-8000-000000000001','有費率社群點',25.073,121.593,'臺北市','松山區','paidMotorcycle',true,
    '{"scooter":{"mode":"per_visit","amount":30,"renew":"midnight"}}','機車每次 30 元，隔日另計；大型重機費率未提供') returning id,updated_at)
  insert into fx select 'structured',id,updated_at from s;

-- #201: fixtures written before eligibility was required state both
-- vehicles (官方未標示 where they left one out), without touching updated_at.
alter table community_spots disable trigger user;
alter table official_heavy_spots disable trigger user;
update community_spots set scooter_not_stated=scooter_allowed is null,heavy_not_stated=heavy_allowed is null
  where scooter_allowed is null or heavy_allowed is null;
update official_heavy_spots set scooter_not_stated=scooter_allowed is null,heavy_not_stated=heavy_allowed is null
  where scooter_allowed is null or heavy_allowed is null;
alter table community_spots enable trigger user;
alter table official_heavy_spots enable trigger user;
select pg_temp.act('admin');
set local role authenticated;
-- An admin edits the text of a fee {} spot, as the form allows.
select is(admin_upsert_spot((select id::text from fx where name='community'),
    '{"fee_note":"每小時 20 元"}',(select at from fx where name='community'))->>'fee_note',
  '每小時 20 元','the text of a community fee {} spot can be saved');
select is(admin_upsert_spot('official:'||(select id from fx where name='official'),
    '{"fee_note":"每次 50 元"}',(select at from fx where name='official'))->>'fee_note',
  '每次 50 元','and of an official one');
-- A structured fee still keeps its text.
select throws_ok($$select admin_upsert_spot((select id::text from fx where name='structured'),
  '{"fee_note":"每小時 30 元"}',(select at from fx where name='structured'))$$,
  '22023','fee_note must be the text of fee','a spot with a vehicle rate still refuses other text');
reset role;
select is((select fee from community_spots where id=(select id from fx where name='community')),'{}'::jsonb,
  'the text edit leaves the stored fee alone');

-- Adopting a report on a fee {} spot.
update fx set at=(select updated_at from community_spots where id=fx.id) where name='community';
insert into moderation_queue(source_id,reason,field,proposed) values
  ((select id::text from fx where name='community'),'空費率：文字','fee_note','{"fee_note":"每次 15 元"}'),
  ((select id::text from fx where name='structured'),'空費率：有費率','fee_note','{"fee_note":"每次 15 元"}');
create temporary table q as select id,reason from moderation_queue where reason like '空費率：%';
grant select on q to authenticated;
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from q where reason='空費率：文字'),'accepted','{"fee_note":"每次 15 元"}')->'spot'->>'fee_note',
  '每次 15 元','a text suggestion is adopted on a fee {} spot');
select throws_ok($$select admin_resolve_report((select id from q where reason='空費率：有費率'),'accepted','{"fee_note":"每次 15 元"}')$$,
  '22023','fee_note must be the text of fee','a text suggestion still cannot drift from a vehicle rate');
reset role;

select * from finish();
rollback;
