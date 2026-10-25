begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Fixtures: rider 0001 reports from two networks, one shared with rider 0002.
update auth.users set raw_user_meta_data='{"display_name":"夜騎50%小哲"}',email='Rider.One@Example.test'
  where id='10000000-0000-4000-8000-000000000001';
update auth.users set raw_user_meta_data='{"full_name":"王小明"}',banned_until=now()-interval '1 day'
  where id='10000000-0000-4000-8000-000000000002';
update auth.users set raw_user_meta_data='{"display_name":"小哲二號"}',banned_until=now()+interval '7 days'
  where id='10000000-0000-4000-8000-000000000006';
insert into rate_limit_events(user_id,ip_hash,created_at) values
  ('10000000-0000-4000-8000-000000000001',repeat('a',64),now()),
  ('10000000-0000-4000-8000-000000000001',repeat('a',64),now()-interval '2 days'),
  ('10000000-0000-4000-8000-000000000001',repeat('b',64),now()-interval '20 days'),
  ('10000000-0000-4000-8000-000000000001',repeat('b',64),now()-interval '40 days'),
  ('10000000-0000-4000-8000-000000000002',repeat('b',64),now()-interval '3 days');
insert into community_spots(id,user_id,name,lat,lng,city,space_type)
values('76000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','使用者頁測試點',25.081,121.601,'臺北市','offStreet');
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
values('76000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','still_there',true,1,repeat('a',64),repeat('a',64));
insert into moderation_queue(source_id,reporter_id,reason,status)
values('76000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','名稱：測試','pending');
create temporary table expected on commit drop as
  select count(*)::text as spots from community_spots where user_id='10000000-0000-4000-8000-000000000001' and source='community';
grant select on expected to authenticated;

select ok(not has_function_privilege('anon','public.admin_users(text,integer)','EXECUTE'),'anonymous callers cannot search users');
select ok(not has_function_privilege('anon','public.admin_user_detail(uuid)','EXECUTE'),'anonymous callers cannot read a user');
select ok(not has_function_privilege('authenticated','public.admin_record_user_ban(uuid,uuid,text,timestamptz,timestamptz,text,text)','EXECUTE'),
  'signed-in users, admins included, cannot write ban records directly');
select ok(not has_function_privilege('anon','public.admin_record_user_ban(uuid,uuid,text,timestamptz,timestamptz,text,text)','EXECUTE'),
  'anonymous callers cannot write ban records');
select ok(not has_function_privilege('authenticated','public.admin_mask_email(text)','EXECUTE'),'the masking helper is private');

-- A rider is refused.
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}',true);
set local role authenticated;
select throws_ok($$select * from admin_users('')$$,'42501',null,'riders cannot search users');
select throws_ok($$select admin_user_detail('10000000-0000-4000-8000-000000000001')$$,'42501',null,'riders cannot read a user');
reset role;

-- An admin without a second factor is refused.
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select throws_ok($$select * from admin_users('')$$,'42501',null,'searching users needs a second factor');
select throws_ok($$select admin_user_detail('10000000-0000-4000-8000-000000000001')$$,'42501',null,'reading a user needs a second factor');
reset role;

select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select is((select array_agg(id order by id) from admin_users('')),
  array['10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002']::uuid[],
  'an empty search lists accounts that reported in the last 30 days');
select is((select id from admin_users('') limit 1),'10000000-0000-4000-8000-000000000001'::uuid,'the most recent reporter comes first');
select is((select reports_30d from admin_users('10000000-0000-4000-8000-000000000001')),3,'reports are counted over 30 days');
select is((select display_name||'|'||email_masked from admin_users('10000000-0000-4000-8000-000000000001')),
  '夜騎50%小哲|Ri***@Example.test','a user id finds the account; the email is masked');
select is((select count(*)::int from admin_users('rider.one@example.TEST')),1,'a complete email matches exactly, ignoring case');
select is((select count(*)::int from admin_users('rider.one@')),0,'part of an email finds nothing');
select is((select array_agg(display_name order by id) from admin_users('小哲')),array['夜騎50%小哲','小哲二號'],'part of the display name finds accounts');
select is((select count(*)::int from admin_users('_')),0,'a wildcard is plain text, not everyone');
select is((select count(*)::int from admin_users('50%')),1,'a percent sign in a name still matches literally');
select is((select banned_until from admin_users('10000000-0000-4000-8000-000000000002')),null,'an expired ban is not shown as banned');
select ok((select banned_until>now() from admin_users('10000000-0000-4000-8000-000000000006')),'a current ban is shown');
select is((select is_admin from admin_users('10000000-0000-4000-8000-000000000005')),true,'administrators are marked');
select is((select providers from admin_users('10000000-0000-4000-8000-000000000001')),array['google'],'sign-in providers are listed');
select throws_ok($$select * from admin_users('',0)$$,'22023',null,'the limit is bounded');
select throws_ok($$select * from admin_users(repeat('車',101))$$,'22023',null,'the query is bounded');

create temporary table d on commit drop as select admin_user_detail('10000000-0000-4000-8000-000000000001') as v;
select is((select v#>>'{limits,today}' from d),'1','today counts against the daily limit');
select is((select v#>>'{limits,last_30d}' from d),'3','30-day reports exclude older events');
select is((select v#>>'{limits,networks_30d}' from d),'2','distinct networks are counted');
select is((select v#>>'{limits,shared_accounts_30d}' from d),'1','another account seen on the same network is counted');
select is((select jsonb_array_length(v->'events') from d),4,'recent events are listed');
select is((select v#>>'{events,0,network}' from d),'aaaaaa','events carry a short network tag');
select ok((select position(repeat('a',64) in v::text)=0 from d),'the full network hash never leaves the database');
select ok((select position('Rider.One@Example.test' in v::text)=0 from d),'the full email never leaves the database');
select is((select v#>>'{reports,spots}' from d),(select spots from expected),'reported points are counted');
select is((select v#>>'{reports,votes_still_there}' from d),'1','votes are counted');
select is((select v#>>'{reports,flags_pending}' from d),'1','pending suggestions are counted');
select is((select v#>>'{spots,0,name_cleared}' from d),'false','a public name not yet cleared');
select is(admin_clear_contributor_name('76000000-0000-4000-8000-000000000001','冒犯字眼')->>'contributor_name','','the admin clears the name from the user page');
select is((admin_user_detail('10000000-0000-4000-8000-000000000001')#>>'{spots,0,name_cleared}'),'true','the cleared name shows as cleared');
select throws_ok($$select admin_user_detail('10000000-0000-4000-8000-0000000000ff')$$,'22023',null,'a missing user is reported');
select throws_ok($$select admin_record_user_ban('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban_user',null,now(),'168h','x')$$,
  '42501',null,'an admin JWT cannot write a ban record without the Edge Function');
reset role;

-- The Edge Function (service role) records the ban the Auth Admin API applied.
set local role service_role;
select throws_ok($$select admin_record_user_ban('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','delete_user',null,null,'','原因')$$,
  '22023',null,'only ban and unban are recorded here');
select throws_ok($$select admin_record_user_ban('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban_user',null,now(),'168h','  ')$$,
  '22023',null,'a ban needs a reason');
select ok(admin_record_user_ban('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban_user',
  null,'2026-11-01T00:00:00Z','168h','  洗版回報  ')>0,'the service role records a ban');
reset role;
select is((select actor::text||'|'||action||'|'||target_table||'|'||note||'|'||(after->>'duration')
  from admin_audit_log where target_id='10000000-0000-4000-8000-000000000001' and action='ban_user'),
  '10000000-0000-4000-8000-000000000005|ban_user|auth.users|洗版回報|168h','the audit entry names the admin, the account and the reason');
select throws_ok($$update admin_audit_log set note='' where action='ban_user'$$,'42501',null,'ban records cannot be changed');

set local role authenticated;
select is((admin_user_detail('10000000-0000-4000-8000-000000000001')#>>'{history,0,action}'),'ban_user','the user page shows the ban history');
reset role;

select * from finish();
rollback;
