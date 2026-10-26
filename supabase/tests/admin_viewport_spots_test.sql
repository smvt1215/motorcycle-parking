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

-- A box away from seeded data: 24.50–24.51, 120.50–120.51.
insert into community_spots(user_id,name,lat,lng,city,space_type,status) values
  ('10000000-0000-4000-8000-000000000001','地圖層社群點',24.501,120.501,'苗栗縣','paidMotorcycle','pending'),
  ('10000000-0000-4000-8000-000000000001','地圖層隱藏社群點',24.502,120.502,'苗栗縣','paidMotorcycle','hidden'),
  ('10000000-0000-4000-8000-000000000001','地圖層框外社群點',24.6,120.6,'苗栗縣','paidMotorcycle','pending');
insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date,hidden) values
  ('地圖層官方點',24.503,120.503,'苗栗縣','https://example.test/a','苗栗縣政府',current_date,false),
  ('地圖層未生效官方點',24.504,120.504,'苗栗縣','https://example.test/b','苗栗縣政府',current_date+30,false),
  ('地圖層隱藏官方點',24.505,120.505,'苗栗縣','https://example.test/c','苗栗縣政府',current_date,true);

create function pg_temp.names(c boolean,o boolean,h boolean) returns text language sql as $$
  select string_agg(name||case when hidden then '(隱藏)' else '' end,',' order by name)
    from admin_viewport_spots(24.5,120.5,24.51,120.51,c,o,h) where name like '地圖層%';
$$;

-- Admins with a second factor only.
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select * from admin_viewport_spots(24.5,120.5,24.51,120.51)$$,'42501',null,'ordinary user is refused');
reset role;
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select * from admin_viewport_spots(24.5,120.5,24.51,120.51)$$,'42501',null,'admin without a second factor is refused');
reset role;
select ok(not has_function_privilege('anon','public.admin_viewport_spots(double precision,double precision,double precision,double precision,boolean,boolean,boolean)','EXECUTE'),'anon cannot call it');

select pg_temp.act('admin');
set local role authenticated;
select is(pg_temp.names(true,true,false),'地圖層官方點,地圖層未生效官方點,地圖層社群點','default layers: visible spots of both kinds, future official ones included');
select is(pg_temp.names(true,false,false),'地圖層社群點','community layer alone');
select is(pg_temp.names(false,true,false),'地圖層官方點,地圖層未生效官方點','official layer alone');
select is(pg_temp.names(false,false,true),'地圖層隱藏官方點(隱藏),地圖層隱藏社群點(隱藏)','hidden layer: hidden spots of either kind, marked hidden');
select is((select id from admin_viewport_spots(24.5,120.5,24.51,120.51,false,true,false) where name='地圖層官方點'),
  'official:'||(select id from official_heavy_spots where name='地圖層官方點'),'official ids carry their prefix');
select is((select status from admin_viewport_spots(24.5,120.5,24.51,120.51,false,true,false) where name='地圖層官方點'),'confirmed','official rows read confirmed, as in the app');
select is((select status from admin_viewport_spots(24.5,120.5,24.51,120.51,false,false,true) where name='地圖層隱藏社群點'),'hidden','hidden community rows keep their status');
select throws_ok($$select * from admin_viewport_spots(24,120,25,121)$$,'22023',null,'a box over 0.5 degree is refused');
select throws_ok($$select * from admin_viewport_spots(24.51,120.5,24.5,120.51)$$,'22023',null,'an inverted box is refused');
reset role;

select * from finish();
rollback;
