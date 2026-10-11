begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(5);
insert into spot_annotations(user_id,source_id,heavy_access,status,updated_at) values
('10000000-0000-4000-8000-000000000001','tdx:Taipei:park:A','denied','confirmed',now()-interval '2 days'),
('10000000-0000-4000-8000-000000000002','tdx:Taipei:park:A','car_space','confirmed',now()-interval '1 day'),
('10000000-0000-4000-8000-000000000003','tdx:Taipei:park:A','allowed','pending',now()),
('10000000-0000-4000-8000-000000000001','tdx:Taipei:park:B','allowed','pending',now()),
('10000000-0000-4000-8000-000000000002','tdx:Taipei:park:C','allowed','hidden',now());
set local role anon;
select is((select heavy_access from confirmed_annotations(array['tdx:Taipei:park:A'])),'car_space','latest confirmed annotation wins over older and pending ones');
select is((select count(*)::integer from confirmed_annotations(array['tdx:Taipei:park:B','tdx:Taipei:park:C'])),0,'pending and hidden annotations are not applied');
select is((select count(*)::integer from confirmed_annotations(array['tdx:Taipei:park:Z'])),0,'unknown ids return nothing');
select is((select count(*)::integer from confirmed_annotations(array(select 'tdx:Taipei:park:A' from generate_series(1,501)))),0,'more than 500 ids rejected');
reset role;
select ok(has_function_privilege('anon','public.confirmed_annotations(text[])','EXECUTE'),'anon can read confirmed annotations');
select * from finish();
rollback;
