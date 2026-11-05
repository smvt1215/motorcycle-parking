begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Fixtures: rider 0001 reports from two networks, one shared with rider 0002.
update auth.users set raw_user_meta_data='{"display_name":"夜騎50%小哲"}',email='Rider.One@Example.test'
  where id='10000000-0000-4000-8000-000000000001';
update auth.users set raw_user_meta_data='{"full_name":"王小明"}'
  where id='10000000-0000-4000-8000-000000000002';
update auth.users set raw_user_meta_data='{"display_name":"小哲二號"}'
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
-- Rider 0003 reported 51 points; the oldest is past the first page.
insert into community_spots(id,user_id,name,lat,lng,city,space_type,created_at)
select ('77000000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'10000000-0000-4000-8000-000000000003',
  '分頁點'||g,25.0+g*0.001,121.5,'臺北市','offStreet',now()-make_interval(days=>g)
from generate_series(1,51) g;
-- Suspensions (#331) live in private.user_suspensions: 0002's has ended,
-- 0006's is current. Written after the rate events (a suspended account's
-- writes are refused).
insert into private.user_suspensions(user_id,until,reason,created_by) values
  ('10000000-0000-4000-8000-000000000002',now()-interval '1 day','過期','10000000-0000-4000-8000-000000000005'),
  ('10000000-0000-4000-8000-000000000006',now()+interval '7 days','洗版','10000000-0000-4000-8000-000000000005');
create temporary table expected on commit drop as
  select count(*)::text as spots from community_spots where user_id='10000000-0000-4000-8000-000000000001' and source='community';
grant select on expected to authenticated;

select ok(not has_function_privilege('anon','public.admin_users(text,integer)','EXECUTE'),'anonymous callers cannot search users');
select ok(not has_function_privilege('anon','public.admin_user_detail(uuid)','EXECUTE'),'anonymous callers cannot read a user');
select ok(not has_function_privilege('anon','public.admin_user_spots(uuid,integer,integer)','EXECUTE'),'anonymous callers cannot page a user''s points');
select ok(not has_function_privilege('authenticated','public.admin_set_user_suspension(uuid,uuid,text,text,text)','EXECUTE'),
  'signed-in users, admins included, cannot suspend directly');
select ok(not has_function_privilege('anon','public.admin_set_user_suspension(uuid,uuid,text,text,text)','EXECUTE'),
  'anonymous callers cannot suspend');
select ok(not has_function_privilege('authenticated','public.admin_mask_email(text)','EXECUTE'),'the masking helper is private');

-- A rider is refused.
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000003","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}',true);
set local role authenticated;
select throws_ok($$select * from admin_users('')$$,'42501',null,'riders cannot search users');
select throws_ok($$select admin_user_detail('10000000-0000-4000-8000-000000000001')$$,'42501',null,'riders cannot read a user');
select throws_ok($$select admin_user_spots('10000000-0000-4000-8000-000000000003',50)$$,'42501',null,'riders cannot page a user''s points');
reset role;

-- An admin without a second factor is refused.
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}',true);
set local role authenticated;
select throws_ok($$select * from admin_users('')$$,'42501',null,'searching users needs a second factor');
select throws_ok($$select admin_user_detail('10000000-0000-4000-8000-000000000001')$$,'42501',null,'reading a user needs a second factor');
select throws_ok($$select admin_user_spots('10000000-0000-4000-8000-000000000003',50)$$,'42501',null,'paging points needs a second factor');
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
reset role;
update private.user_suspensions set until=null where user_id='10000000-0000-4000-8000-000000000006';
set local role authenticated;
select is((select banned_until from admin_users('10000000-0000-4000-8000-000000000006')),'9999-12-31T00:00:00Z'::timestamptz,
  'an indefinite suspension is shown as 9999-12-31 (the admin page reads 10+ years as indefinite)');
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
select is(jsonb_array_length(admin_user_detail('10000000-0000-4000-8000-000000000003')->'spots'),50,'the user page shows the newest 50 points');
select is((admin_user_detail('10000000-0000-4000-8000-000000000003')#>>'{reports,spots}'),'51','the count still covers every point');
select is((select string_agg(e->>'name',',') from jsonb_array_elements(admin_user_spots('10000000-0000-4000-8000-000000000003',50)) e),'分頁點51',
  'the next page reaches the oldest point');
select is(admin_clear_contributor_name('77000000-0000-4000-8000-000000000051','')->>'contributor_name','','a point past the first page can be cleared');
select is((admin_user_spots('10000000-0000-4000-8000-000000000003',50)#>>'{0,name_cleared}'),'true','clearing does not move a point to another page');
select throws_ok($$select admin_user_spots('10000000-0000-4000-8000-000000000003',-1)$$,'22023',null,'the offset cannot be negative');
select throws_ok($$select admin_user_spots('10000000-0000-4000-8000-000000000003',0,101)$$,'22023',null,'the page size is bounded');
select throws_ok($$select admin_user_detail('10000000-0000-4000-8000-0000000000ff')$$,'22023',null,'a missing user is reported');
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban','7d','x')$$,
  '42501',null,'an admin JWT cannot suspend without the Edge Function');
reset role;

-- The Edge Function (service role) suspends and audits in one call (#331).
set local role service_role;
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','delete','7d','原因')$$,
  '22023',null,'only ban and unban are done here');
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban','168h','原因')$$,
  '22023',null,'only the durations the admin page offers');
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban','7d','  ')$$,
  '22023',null,'a ban needs a reason');
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000005','ban','7d','原因')$$,
  '42501',null,'an administrator cannot be suspended');
select throws_ok($$select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-0000000000ff','ban','7d','原因')$$,
  'P0002',null,'a missing account cannot be suspended');
create temporary table ban_result on commit drop as
  select admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban','7d','  洗版回報  ') v;
select is((select v->>'before' from ban_result),null,'not suspended before');
select ok((select (v->>'after')::timestamptz between now()+interval '7 days'-interval '1 minute' and now()+interval '7 days' from ban_result),
  'suspended for 7 days');
reset role;
select ok(is_suspended('10000000-0000-4000-8000-000000000001'),'the account is suspended');
select is((select reason||'|'||created_by from private.user_suspensions where user_id='10000000-0000-4000-8000-000000000001'),
  '洗版回報|10000000-0000-4000-8000-000000000005','the suspension keeps the reason and who set it');
select is((select actor::text||'|'||action||'|'||target_table||'|'||note||'|'||(after->>'duration')
  from admin_audit_log where target_id='10000000-0000-4000-8000-000000000001' and action='ban_user'),
  '10000000-0000-4000-8000-000000000005|ban_user|auth.users|洗版回報|7d','the audit entry names the admin, the account and the reason');
select is((select banned_until from auth.users where id='10000000-0000-4000-8000-000000000001'),null,'Auth is not banned: the account can still sign in');
set local role service_role;
select ok((select (admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','ban','indefinite','改為無限期')->>'after')::timestamptz
  ='9999-12-31T00:00:00Z'::timestamptz),'an indefinite suspension');
select is((admin_set_user_suspension('10000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','unban',null,'申訴成立')->>'after'),
  null,'unbanning lifts it');
reset role;
select ok(not is_suspended('10000000-0000-4000-8000-000000000001'),'the account is no longer suspended');
select is((select before->>'banned_until' from admin_audit_log where target_id='10000000-0000-4000-8000-000000000001' and action='unban_user')::timestamptz,
  '9999-12-31T00:00:00Z'::timestamptz,'the unban audit keeps what it lifted');
select throws_ok($$update admin_audit_log set note='' where action='ban_user'$$,'42501',null,'ban records cannot be changed');

set local role authenticated;
select ok((admin_user_detail('10000000-0000-4000-8000-000000000001')->'history') @> '[{"action":"ban_user"},{"action":"unban_user"}]',
  'the user page shows the ban history');
reset role;

select * from finish();
rollback;
