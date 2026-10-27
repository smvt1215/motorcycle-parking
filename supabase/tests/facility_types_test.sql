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
create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;

-- An old writer sends facility_type only: one-element set.
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,facility_type)
  values('10000000-0000-4000-8000-000000000001','型式舊寫法',25.011,121.511,'臺北市','offStreet','underground') returning id)
  insert into fx select 'old',id from s;
select is((select facility_types from community_spots where id=(select id from fx where name='old')),
  array['underground'],'facility_type alone is stored as a one-element set');

-- A new writer sends the set: stored in contract order, facility_type is its first.
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,facility_types)
  values('10000000-0000-4000-8000-000000000001','型式複選',25.012,121.512,'臺北市','offStreet',array['roadside','surface','underground']) returning id)
  insert into fx select 'multi',id from s;
select is((select facility_types from community_spots where id=(select id from fx where name='multi')),
  array['underground','surface','roadside'],'the set is stored in the contract order');
select is((select facility_type from community_spots where id=(select id from fx where name='multi')),
  'underground','facility_type is the first of the set, a lot type when any is');

-- Updates: the set wins; facility_type alone replaces the set.
update community_spots set facility_types=array['surface','multiStorey'],facility_type='roadside' where id=(select id from fx where name='multi');
select is((select facility_type||'|'||array_to_string(facility_types,',') from community_spots where id=(select id from fx where name='multi')),
  'multiStorey|multiStorey,surface','a set sent with a different facility_type wins');
update community_spots set facility_type='surface' where id=(select id from fx where name='old');
select is((select facility_types from community_spots where id=(select id from fx where name='old')),
  array['surface'],'an old build changing facility_type replaces the set');
update community_spots set facility_types=null where id=(select id from fx where name='old');
select is((select facility_type from community_spots where id=(select id from fx where name='old')),
  null,'clearing the set clears facility_type');

-- Only non-empty sets of distinct contract values.
select throws_ok($$update community_spots set facility_types='{}' where id=(select id from fx where name='multi')$$,
  '23514',null,'an empty set is refused');
select throws_ok($$update community_spots set facility_types=array['surface','surface'] where id=(select id from fx where name='multi')$$,
  '23514',null,'a repeated type is refused');
select throws_ok($$update community_spots set facility_types=array['tower'] where id=(select id from fx where name='multi')$$,
  '23514',null,'an unknown type is refused');
select throws_ok($$update community_spots set facility_types=array['surface',null] where id=(select id from fx where name='multi')$$,
  '23514',null,'a null type is refused');

-- Rules read "any of them": a street bay with a lot among its types is off
-- the street, so it may not keep a street condition.
select throws_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,facility_types,condition)
  values('10000000-0000-4000-8000-000000000001','路邊加平面',25.013,121.513,'臺北市','paidMotorcycle',array['roadside','surface'],
  '{"bay":"motorcycle","use":"usual","charge":"toll"}')$$,'23514',null,'any lot type places the spot off the street');
select lives_ok($$insert into community_spots(user_id,name,lat,lng,city,space_type,facility_types,condition)
  values('10000000-0000-4000-8000-000000000001','只有路邊',25.014,121.514,'臺北市','paidMotorcycle',array['roadside'],
  '{"bay":"motorcycle","use":"usual","charge":"toll"}')$$,'a roadside bay keeps its street condition');

-- Readers: public_spots and the viewports; old viewports keep facility_type.
set local role anon;
select is((select facility_types from public_spots where name='型式複選'),array['multiStorey','surface'],'public_spots carries the set');
select is((select facility_type from viewport_spots(25.0,121.5,25.02,121.52) where name='型式複選'),'multiStorey',
  'the original viewport still reads facility_type');
select is((select facility_types from viewport_spots_v3(25.0,121.5,25.02,121.52) where name='型式複選'),array['multiStorey','surface'],
  'viewport v3 carries the set');
reset role;
insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date,space_type,facility_types)
  values('官方型式複選',24.80,120.97,'新竹市','https://data.gov.tw/dataset/1',current_date-1,'offStreet',array['surface','underground']);
set local role anon;
select is((select facility_type||'|'||array_to_string(facility_types,',') from official_viewport_spots_v3(24.79,120.96,24.81,120.98) where name='官方型式複選'),
  'underground|underground,surface','official v3 carries the set and its first type');
select is((select facility_type from official_viewport_spots_v2(24.79,120.96,24.81,120.98) where name='官方型式複選'),'underground',
  'official v2 still reads facility_type');
reset role;

-- A rider's report and an admin's edit write the set.
create temporary table lot as select (public.apply_report('10000000-0000-4000-8000-000000000001',repeat('b',64),repeat('b',64),
  '{"action":"create","spot":{"name":"回報複選停車場","lat":25.06,"lng":121.58,"city":"臺北市","space_type":"offStreet",
    "facility_type":"surface","facility_types":["surface","underground"]}}')->>'id')::uuid as id;
grant select on lot to authenticated;
select is((select facility_type||'|'||array_to_string(facility_types,',') from community_spots where id=(select id from lot)),
  'underground|underground,surface','apply_report stores the set');
select pg_temp.act('admin');
set local role authenticated;
select is(admin_upsert_spot((select id::text from lot),'{"facility_types":["multiStorey","roadside"]}',
  (select updated_at from community_spots where id=(select id from lot)))->'facility_types',
  '["multiStorey","roadside"]'::jsonb,'admin_upsert_spot writes the set');
select ok('facility_types'=any(admin_spot_fields(false)) and 'facility_types'=any(admin_spot_fields(true)),'admin forms may send the set');
reset role;
select ok('facility_types'=any(spot_history_fields()) and 'facility_types'=any(spot_history_public_fields()),'the history records the set');
select is(moderation_key_risk('facility_types','{}','{}'),2,'a suggested set is medium risk like facility_type');


-- An import file of the old shape (facility_type only) keeps a stored set
-- while the type is the stored first one, and replaces it otherwise.
insert into official_heavy_spots(id,name,lat,lng,city,source_url,source_name,source_id,effective_date,space_type,facility_types)
  values('30000000-0000-4000-8000-000000000001','匯入型式',24.5,121.0,'新竹縣','https://data.gov.tw/dataset/2','新竹縣政府','F1',
    current_date-1,'offStreet',array['underground','surface']);
create temporary table import_file(spots jsonb);
grant select on import_file to authenticated;
insert into import_file values(jsonb_build_array(jsonb_build_object(
  'id','official:30000000-0000-4000-8000-000000000001','source','official','name','匯入型式',
  'lat',24.5,'lng',121.0,'city','新竹縣','space_type','offStreet','facility_type','underground',
  'source_url','https://data.gov.tw/dataset/2','source_name','新竹縣政府','source_id','F1')));
select pg_temp.act('admin');
set local role authenticated;
select ok(not exists(select 1 from jsonb_array_elements(admin_import_preview((select spots from import_file))) p,
    jsonb_array_elements(p->'changes') c where c->>'field' like 'facility%'),
  'an old file with the stored first type changes no type');
reset role;
update import_file set spots=jsonb_set(spots,'{0,facility_type}','"surface"');
select pg_temp.act('admin');
set local role authenticated;
select is((select c->'incoming' from jsonb_array_elements(admin_import_preview((select spots from import_file))) p,
    jsonb_array_elements(p->'changes') c where c->>'field'='facility_types'),
  '["surface"]'::jsonb,'an old file with another type proposes it as the set');
select is((admin_import_apply((select spots from import_file),
    jsonb_build_object('official:30000000-0000-4000-8000-000000000001',jsonb_build_object('base_updated_at',
      (select updated_at from official_heavy_spots where id='30000000-0000-4000-8000-000000000001'))),
    null))->>'updated','1','the import applies');
reset role;
select is((select facility_type||'|'||array_to_string(facility_types,',') from official_heavy_spots
  where id='30000000-0000-4000-8000-000000000001'),'surface|surface','the type and the set are the file''s');

-- History: snapshots from before the set compare facility_type; rows with
-- the set list only the set.
select is(spot_history_changes('{"facility_type":"surface"}','{"facility_type":"underground"}')->0->>'field',
  'facility_type','an old snapshot still records a change of type');
select is(spot_history_changes(
    '{"facility_type":"surface","facility_types":["surface"]}',
    '{"facility_type":"underground","facility_types":["underground","surface"]}'),
  '[{"field":"facility_types","before":["surface"],"after":["underground","surface"]}]'::jsonb,
  'a row with the set records the set once');

-- A report from before the set (its base_spot has facility_type only) is
-- not a conflict for a suggested set.
insert into moderation_queue(source_id,reason,field,proposed)
  values('official:30000000-0000-4000-8000-000000000001','場站型式','space_type','{"facility_types":["surface","underground"]}');
update moderation_queue set base_spot=base_spot-'facility_types' where reason='場站型式';
select pg_temp.act('admin');
set local role authenticated;
select lives_ok($$select admin_resolve_report((select id from moderation_queue where reason='場站型式'),'accepted',
  '{"facility_types":["surface","underground"]}')$$,'an old report applies a set without a false conflict');
reset role;
select is((select facility_types from official_heavy_spots where id='30000000-0000-4000-8000-000000000001'),
  array['underground','surface'],'the suggested set is stored');

select * from finish();
rollback;
