begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(9);
insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date) values
('[測試] 公告重機格',25.00,121.50,'新北市','https://www.example.gov.tw/a',current_date-1),
('[測試] 尚未生效',25.001,121.501,'新北市','https://www.example.gov.tw/b',current_date+1),
('[測試] 視窗外',24.15,120.67,'臺中市','https://www.example.gov.tw/c',current_date);
set local role anon;
select is((select count(*)::integer from official_viewport_spots(24.999,121.499,25.01,121.51)),1,'only effective spots inside the viewport');
select is((select source||'|'||space_type||'|'||status||'|'||heavy_allowed::text from official_viewport_spots(24.999,121.499,25.01,121.51)),'official|heavyOnly|confirmed|true','rows default to confirmed heavy-only official bays');
select ok((select id like 'official:%' from official_viewport_spots(24.999,121.499,25.01,121.51)),'ids are namespaced');
select is((select count(*)::integer from official_heavy_spots where name='[測試] 尚未生效'),0,'rows stay hidden until their effective date');
select is((select count(*)::integer from official_viewport_spots(20,118,27,123)),0,'broad queries rejected');
select is((select count(*)::integer from official_viewport_spots(25.1,121.6,25.0,121.5)),0,'reversed bounds rejected');
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date) values('x',25,121.5,'臺北市','https://a.gov.tw',current_date)$$,'42501',null,'clients cannot write official spots');
reset role;
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,space_type,source_url,effective_date) values('x',25,121.5,'臺北市','bike','https://a.gov.tw',current_date)$$,'23514',null,'unknown space types rejected');
select throws_ok($$insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date) values('x',25,121.5,'臺北市','javascript:alert(1)',current_date)$$,'23514',null,'source links must be https');
select * from finish();
rollback;
