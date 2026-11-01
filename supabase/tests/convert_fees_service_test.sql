-- 費率轉換 CLI 的寫入路徑（#235；202611011200_convert_fees_service.sql）：
-- service role 以指定的管理者身分寫入並留稽核；管理站的 admin_convert_fees
-- 行為不變；內部的 convert_fees_for 誰都不能直接呼叫。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

insert into auth.users(id,instance_id,aud,role,email,created_at,updated_at,is_anonymous,raw_app_meta_data,raw_user_meta_data,banned_until)
values
  ('40000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'fee-admin@example.test',now(),now(),false,'{"provider":"google","role":"admin"}','{}',null),
  ('40000000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'fee-rider@example.test',now(),now(),false,'{"provider":"google","role":"user"}','{}',null),
  ('40000000-0000-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'fee-banned@example.test',now(),now(),false,'{"provider":"google","role":"admin"}','{}',now()+interval '1 day');

insert into official_heavy_spots(id,name,lat,lng,city,district,space_type,fee_note,note,source_url,source_name,source_id,
    effective_date,scooter_allowed,heavy_allowed,heavy_not_stated)
  values('41000000-0000-4000-8000-000000000001','費率轉換測試停車場',25.04,121.51,'臺北市','中正區','offStreet','機車計次20元;','',
    'https://data.example.test/fee','臺北市政府','FEE1','2026-10-17',true,null,true);
insert into community_spots(id,user_id,source,name,lat,lng,city,district,space_type,fee_note)
  values('41000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000002','import','費率轉換測試社群點',
    25.05,121.52,'臺北市','中正區','heavyOnly','每小時 30 元');

create function pg_temp.items() returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('source_id','official:41000000-0000-4000-8000-000000000001','fee_note','機車計次20元;','space_type','offStreet',
      'fee',jsonb_build_object('scooter',jsonb_build_object('mode','per_visit','amount',20))),
    jsonb_build_object('source_id','41000000-0000-4000-8000-000000000002','fee_note','每小時 30 元','space_type','heavyOnly',
      'fee',jsonb_build_object('heavy',jsonb_build_object('mode','hourly','amount',30,'per_minutes',60))),
    jsonb_build_object('source_id','41000000-0000-4000-8000-000000000002','fee_note','舊的說明','space_type','heavyOnly',
      'fee',jsonb_build_object('heavy',jsonb_build_object('mode','free'))));
$$;

-- Only the service role; the core is nobody's to call.
select ok(not has_function_privilege('anon','public.admin_convert_fees_as(uuid,jsonb,text)','EXECUTE'),'anon cannot convert as an admin');
select ok(not has_function_privilege('authenticated','public.admin_convert_fees_as(uuid,jsonb,text)','EXECUTE'),'signed-in users cannot convert as an admin');
select ok(has_function_privilege('service_role','public.admin_convert_fees_as(uuid,jsonb,text)','EXECUTE'),'the service role can');
select ok(not has_function_privilege(r,'public.convert_fees_for(uuid,jsonb,text)','EXECUTE'),r||' cannot call the core')
  from unnest(array['anon','authenticated','service_role']) r;
-- The admin site's RPC keeps its grants.
select ok(has_function_privilege('authenticated','public.admin_convert_fees(jsonb,text)','EXECUTE'),'admin_convert_fees keeps its grant');

set local role service_role;
select throws_ok($$select admin_convert_fees('[]')$$,'42501',null,'the service role has no admin session for admin_convert_fees');
select throws_ok($$select admin_convert_fees_as('40000000-0000-4000-8000-000000000002',pg_temp.items(),'#235')$$,
  '42501',null,'the actor must be an admin');
select throws_ok($$select admin_convert_fees_as('40000000-0000-4000-8000-000000000003',pg_temp.items(),'#235')$$,
  '42501',null,'a banned admin cannot be the actor');
select throws_ok($$select admin_convert_fees_as('40000000-0000-4000-8000-0000000000ff',pg_temp.items(),'#235')$$,
  '42501',null,'the actor must exist');
select throws_ok($$select admin_convert_fees_as(null,pg_temp.items(),'#235')$$,'42501',null,'an actor is required');
select throws_ok($$select admin_convert_fees_as('40000000-0000-4000-8000-000000000001',pg_temp.items(),'  ')$$,
  '22023',null,'a note is required');
select throws_ok($$select admin_convert_fees_as('40000000-0000-4000-8000-000000000001',
  (select jsonb_agg(x) from generate_series(1,501) x),'#235')$$,'22023',null,'at most 500 a call');
select is(admin_convert_fees_as('40000000-0000-4000-8000-000000000001',pg_temp.items(),' #235 staging '),
  '{"converted":2,"skipped":[{"reason":"已有結構化費率","source_id":"41000000-0000-4000-8000-000000000002"}]}'::jsonb,
  'both written; a second item for a converted spot is skipped');
reset role;

select is((select fee from official_heavy_spots where id='41000000-0000-4000-8000-000000000001'),
  '{"scooter":{"mode":"per_visit","amount":20}}'::jsonb,'the official fee is written');
select is((select fee_note||'|'||fee_source_text from community_spots where id='41000000-0000-4000-8000-000000000002'),
  public.fee_note_of('{"heavy":{"mode":"hourly","amount":30,"per_minutes":60}}')||'|每小時 30 元','the note read becomes the source text');
select is((select count(*)::integer from admin_audit_log where action='convert_fee'
    and actor='40000000-0000-4000-8000-000000000001' and note='#235 staging'),2,'audited under the admin, with the note');
select is((select before->>'fee_note' from admin_audit_log where action='convert_fee'
    and target_table='official_heavy_spots' and target_id='41000000-0000-4000-8000-000000000001'),
  '機車計次20元;','the audit keeps the note before');

select * from finish();
rollback;
