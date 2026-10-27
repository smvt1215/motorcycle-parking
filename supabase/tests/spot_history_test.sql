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

create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
with s as (insert into community_spots(user_id,name,lat,lng,city,district,space_type,scooter_allowed,heavy_allowed,note,entrance_note,created_at)
  values('10000000-0000-4000-8000-000000000001','編輯紀錄測試點',25.051,121.571,'臺北市','松山區','freeMotorcycle',true,null,
    '請電 0912-345-678','從忠孝東路五段入口進',now()-interval '30 days') returning id)
  insert into fx select 'community',id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,source_name,effective_date)
  values('編輯紀錄官方點',25.052,121.572,'臺北市','https://example.test/notice','臺北市停管處',current_date) returning id)
  insert into fx select 'official',id from s;

-- Timeline on the community spot: a note with a phone number an admin later
-- removed, an accepted report, a rejected report, an import-only field.
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','update_spot','community_spots',f.id::text,
  '{"note":"","name":"編輯紀錄測試點"}','{"note":"請電 0912-345-678","name":"編輯紀錄測試點"}','誤植',now()-interval '20 days'
from fx f where f.name='community';
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','update_spot','community_spots',f.id::text,
  '{"note":"請電 0912-345-678","heavy_verified_at":null}','{"note":"","heavy_verified_at":"2026-10-20T00:00:00Z"}','移除個資',now()-interval '19 days'
from fx f where f.name='community';
update community_spots set note='' where id=(select id from fx where name='community');
with q as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note,status,resolved_at,resolved_by,resolution_note,created_at)
  select f.id::text,'10000000-0000-4000-8000-000000000002','入口：從忠孝東路五段入口進','entrance_note',
    '{"entrance_note":"從忠孝東路五段入口進"}','我昨天去過','accepted',now()-interval '10 days',
    '10000000-0000-4000-8000-000000000005','現場確認',now()-interval '11 days' from fx f where f.name='community' returning id)
  insert into fx select 'accepted',id from q;
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','resolve_report','moderation_queue',q.id::text,
  jsonb_build_object('report','{}'::jsonb,'spot',jsonb_build_object('id',c.id,'entrance_note','')),
  jsonb_build_object('status','accepted','spot_table','community_spots','spot',jsonb_build_object('id',c.id,'entrance_note','從忠孝東路五段入口進')),
  '現場確認',now()-interval '10 days'
from fx q, fx c where q.name='accepted' and c.name='community';
with q as (insert into moderation_queue(source_id,reporter_id,reason,status,resolved_at,resolved_by,resolution_note,resolution_kind,created_at)
  select f.id::text,'10000000-0000-4000-8000-000000000002','這裡不收費','rejected',now()-interval '5 days',
    '10000000-0000-4000-8000-000000000005','照片看得到收費牌','wrong',now()-interval '6 days' from fx f where f.name='community' returning id)
  insert into fx select 'rejected',id from q;
insert into moderation_queue(source_id,reason,created_at)
  select f.id::text,'還沒處理的回報',now()-interval '1 day' from fx f where f.name='community';
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','clear_contributor_name','community_spots',f.id::text,
  '{"contributor_name":"小明"}','{"contributor_name":""}','',now()-interval '2 days'
from fx f where f.name='community';

-- The official spot: created by import, then a later import.
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','import_spot','official_heavy_spots',f.id::text,
  null,jsonb_build_object('id',f.id,'name','編輯紀錄官方點','scooter_total',120,'source_name','臺北市停管處'),'',now()-interval '9 days'
from fx f where f.name='official';
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','import_spot','official_heavy_spots',f.id::text,
  jsonb_build_object('scooter_total',120,'address','','source_name','臺北市停管處'),jsonb_build_object('scooter_total',150,'address','忠孝東路五段 1 號','source_name','臺北市停管處'),'',now()-interval '3 days'
from fx f where f.name='official';
update official_heavy_spots set scooter_total=150,address='忠孝東路五段 1 號' where id=(select id from fx where name='official');

-- Only administrators with a second factor read the full timeline.
select ok(not has_function_privilege('anon','public.admin_spot_history(text)','EXECUTE'),'anon cannot read the admin timeline');
select ok(not has_function_privilege('anon','public.spot_history_entries(text)','EXECUTE'),'the shared query is not callable by anon');
select ok(not has_function_privilege('authenticated','public.spot_history_entries(text)','EXECUTE'),'nor by signed-in users');
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select admin_spot_history((select id::text from fx where name='community'))$$,'42501',null,'admin without a second factor is refused');
reset role;
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_spot_history((select id::text from fx where name='community'))$$,'42501',null,'an ordinary user is refused');
reset role;

select pg_temp.act('admin');
set local role authenticated;
create temporary table h on commit drop as select admin_spot_history((select id::text from fx where name='community')) as v;
reset role;
select is((select jsonb_array_length(v) from h),6,'four audited writes or decisions, plus the rider creation; pending reports are left out');
select is((select v->0->>'action' from h),'clear_contributor_name','newest first');
select is((select v->1->>'kind' from h),'report','a rejected report is a rider entry');
select is((select v->1->'report'->>'status' from h),'rejected','with its decision');
select is((select v->1->'report'->>'resolution_kind' from h),'wrong','and why it was rejected');
select is((select jsonb_array_length(v->1->'changes') from h),0,'a rejection changes nothing');
select is((select v->2->'report'->>'note' from h),'我昨天去過','the original report comes along');
select is((select v->2->'changes' from h),'[{"field":"entrance_note","after":"從忠孝東路五段入口進","before":""}]'::jsonb,'what the acceptance changed');
select is((select v->2->>'actor_name' from h),'','an admin without a display name shows none');
select is((select v->3->'changes'->0->>'field' from h),'heavy_verified_at','order follows the field list');
select is((select v->3->'changes'->1->>'before' from h),'請電 0912-345-678','admins see the before value');
select is((select v->5->>'action' from h),'create','the rider creation is the first entry');
select ok((select (v->5->>'created')::boolean from h),'marked as the creation');
select is((select v->5->>'kind' from h),'report','by a rider');

-- The app's version: no people, notes, reports, rejections or removed text.
set local role anon;
create temporary table p on commit drop as select spot_history((select id::text from fx where name='community')) as v;
create temporary table o on commit drop as select spot_history('official:'||(select id from fx where name='official')) as v;
reset role;
select is((select jsonb_array_length(v) from p),4,'the clear and the rejection drop out; the admin note edits stay');
select ok((select not (v::text ~ '("(actor|actor_name|note|report|reason)":|0912|小明)') from p),'nothing about people, notes, reports or removed text');
select is((select v->0->'changes' from p),'[{"field":"entrance_note","after":"從忠孝東路五段入口進"}]'::jsonb,'a value the spot still holds is shown');
select is((select v->1->'changes' from p),'[{"field":"note","after":""}]'::jsonb,'only public fields, the administrator''s check is left out');
select is((select v->2->'changes' from p),'[{"field":"note"}]'::jsonb,'a value the spot no longer holds is not shown');
select is((select v->3->>'kind' from p),'report','the rider creation');
select is((select jsonb_array_length(v) from o),2,'the official spot: creation and an update');
select is((select v->0->'changes' from o),'[{"field":"address","after":"忠孝東路五段 1 號"},{"field":"scooter_total","after":150}]'::jsonb,'import changes in field order');
select ok((select (v->1->>'created')::boolean and v->1->>'kind'='import' from o),'created by import');

-- Hidden spots and nonsense ids have no history.
update community_spots set status='hidden' where id=(select id from fx where name='community');
set local role anon;
select is(spot_history((select id::text from fx where name='community')),'[]'::jsonb,'a hidden spot shows no history');
select is(spot_history('not-a-uuid'),'[]'::jsonb,'an id that is not a spot');
select is(spot_history(null),'[]'::jsonb,'no id');
reset role;

-- Only the latest 10.
insert into admin_audit_log(actor,action,target_table,target_id,before,after,note,created_at)
select '10000000-0000-4000-8000-000000000005','update_spot','official_heavy_spots',f.id::text,
  jsonb_build_object('name','n'||g),jsonb_build_object('name','n'||(g+1)),'',now()-interval '1 hour'*g
from fx f, generate_series(1,12) g where f.name='official';
set local role anon;
select is(jsonb_array_length(spot_history('official:'||(select id from fx where name='official'))),10,'at most 10 entries');
reset role;

select * from finish();
rollback;
