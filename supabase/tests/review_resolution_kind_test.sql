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
create function pg_temp.queue(p_name text,p_source text,p_field text,p_proposed jsonb,p_reason text default 'x') returns void language sql as $$
  with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
    values(p_source,'10000000-0000-4000-8000-000000000002',p_reason||p_name,p_field,p_proposed) returning id)
  insert into fx select p_name,id from s;
$$;
create function pg_temp.risk(p_name text) returns text language sql as $$
  select risk from moderation_queue where id=(select id from fx where name=p_name);
$$;

delete from moderation_queue;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','風險測試點',25.042,121.562,'臺北市','paidMotorcycle') returning id)
  insert into fx select 'spot',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','路外測試點',25.044,121.564,'臺北市','offStreet') returning id)
  insert into fx select 'lot',id from s;

-- Risk is derived on insert from what the report proposes (§5.1).
select pg_temp.queue('name',(select id::text from fx where name='spot'),'name','{"name":"新名稱"}');
select pg_temp.queue('guide',(select id::text from fx where name='spot'),'guide','{"entrance_note":"由後門進入"}');
select pg_temp.queue('fee',(select id::text from fx where name='spot'),'fee_note','{"fee_note":"每次 20 元"}');
select pg_temp.queue('type_street',(select id::text from fx where name='spot'),'space_type','{"space_type":"freeMotorcycle"}');
select pg_temp.queue('type_cross',(select id::text from fx where name='spot'),'space_type','{"space_type":"offStreet"}');
select pg_temp.queue('type_out',(select id::text from fx where name='lot'),'space_type','{"space_type":"paidMotorcycle"}');
select pg_temp.queue('lot_facility',(select id::text from fx where name='lot'),'space_type','{"space_type":"offStreet","facility_type":"underground"}');
select pg_temp.queue('type_none',(select id::text from fx where name='spot'),'space_type',null);
select pg_temp.queue('access',(select id::text from fx where name='spot'),'eligibility','{"heavy_allowed":true}');
select pg_temp.queue('gone',(select id::text from fx where name='spot'),'gone','{"status":"hidden"}');
select pg_temp.queue('near',(select id::text from fx where name='spot'),'location','{"lat":25.0425,"lng":121.562}');
select pg_temp.queue('far',(select id::text from fx where name='spot'),'location','{"lat":25.05,"lng":121.562}');
select pg_temp.queue('bad_coord',(select id::text from fx where name='spot'),'location','{"lat":"north","lng":121.562}');
select pg_temp.queue('mixed',(select id::text from fx where name='spot'),'name','{"name":"新名稱","heavy_allowed":true}');
select pg_temp.queue('legacy',(select id::text from fx where name='spot'),'停車點名稱',null);
select pg_temp.queue('free_text',(select id::text from fx where name='spot'),null,null,'其他：');
select pg_temp.queue('unknown',(select id::text from fx where name='spot'),'whatever','{"note":"x"}');
with s as (insert into moderation_queue(source_id,reason)
  values((select id::text from fx where name='lot'),'加權負向回報達門檻') returning id) insert into fx select 'votes',id from s;

select is(pg_temp.risk('name'),'low','a name change is low risk');
select is(pg_temp.risk('guide'),'low','entrance directions are low risk');
select is(pg_temp.risk('fee'),'medium','a fee change is medium risk');
select is(pg_temp.risk('type_street'),'medium','a type change between street bays is medium risk');
select is(pg_temp.risk('type_cross'),'high','a street bay turned off-street is high risk');
select is(pg_temp.risk('type_out'),'high','an off-street lot turned street bay is high risk');
select is(pg_temp.risk('lot_facility'),'medium','restating an off-street type with a facility change stays medium');
select is(pg_temp.risk('type_none'),'high','a type report without a value is high risk');
select is(pg_temp.risk('access'),'high','vehicle access is high risk');
select is(pg_temp.risk('gone'),'medium','a gone report is medium risk');
select is(pg_temp.risk('votes'),'medium','a vote-triggered gone report is medium risk');
select is(pg_temp.risk('near'),'medium','a move within 150 m is medium risk');
select is(pg_temp.risk('far'),'high','a move over 150 m is high risk');
select is(pg_temp.risk('bad_coord'),'high','a coordinate that is not a number is high risk, and still queued');
select is(pg_temp.risk('mixed'),'high','the riskiest proposed column wins');
select is(pg_temp.risk('legacy'),'low','older builds'' Chinese labels are understood');
select is(pg_temp.risk('free_text'),'high','a report with nothing structured is high risk');
select is(pg_temp.risk('unknown'),'high','an unknown category is high risk');
select ok(not has_function_privilege('authenticated','public.moderation_risk(text,text,jsonb,jsonb)','EXECUTE'),'the risk function is private');

-- Only admins with a second factor resolve, with or without a kind.
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from fx where name='name'),'rejected',p_resolution_kind=>'wrong')$$,'42501',null,'an ordinary user cannot reject');
reset role;
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select admin_resolve_report((select id from fx where name='name'),'rejected',p_resolution_kind=>'wrong')$$,'42501',null,'an admin without a second factor cannot reject');
reset role;

select pg_temp.act('admin');
set local role authenticated;
-- The call older admin builds make: rejecting without a kind is refused and
-- the report stays pending; accepting the same way still works.
select throws_ok($$select admin_resolve_report(p_id=>(select id from fx where name='name'),p_decision=>'rejected',p_patch=>'{}',p_note=>'',p_force=>false)$$,
  '22023','a rejection needs a resolution kind','an older call that rejects without a kind is refused');
select throws_ok($$select admin_resolve_report((select id from fx where name='name'),'rejected',p_resolution_kind=>'  ')$$,
  '22023','a rejection needs a resolution kind','a blank kind is no kind');
select throws_ok($$select admin_resolve_report((select id from fx where name='name'),'rejected',p_resolution_kind=>'spam')$$,
  '22023','invalid resolution kind','unknown kinds are refused');
select throws_ok($$select admin_resolve_report((select id from fx where name='name'),'rejected',null,'  ',p_resolution_kind=>'other')$$,
  '22023','resolution kind other needs a note','other without a note is refused');
select is((select status from moderation_queue where id=(select id from fx where name='name')),'pending','a refused rejection leaves the report pending');
select is(admin_resolve_report(p_id=>(select id from fx where name='guide'),p_decision=>'accepted',p_patch=>'{"entrance_note":"由後門進入"}',p_note=>'',p_force=>false)->>'status',
  'accepted','an older call that accepts still works');
select is((select resolution_kind from moderation_queue where id=(select id from fx where name='guide')),null,'accepting needs no kind');

select is(admin_resolve_report((select id from fx where name='name'),'rejected',null,'已有相同名稱建議',p_resolution_kind=>'duplicate')->>'resolution_kind',
  'duplicate','a rejection with a kind is recorded');
select is((select resolution_kind from moderation_queue where id=(select id from fx where name='name')),'duplicate','the kind is stored on the report');
-- 202610260010's fee check still runs in the redefined RPC.
select throws_ok($$select admin_resolve_report((select id from fx where name='fee'),'accepted',
  '{"fee":{"scooter":{"mode":"daily","amount":30}},"fee_note":"每日 30 元"}',p_resolution_kind=>'other',p_note=>'改為結構化費率')$$,
  '22023','fee_note must be the text of fee','the fee text check survives alongside the resolution kind');
select is((select status from moderation_queue where id=(select id from fx where name='fee')),'pending','a refused fee patch leaves the report pending');
-- Closing without a change may say why.
select is(admin_resolve_report((select id from fx where name='fee'),'accepted',null,'',p_resolution_kind=>'outdated')->>'status','accepted','closing may carry a kind');
select is((select resolution_kind from moderation_queue where id=(select id from fx where name='fee')),'outdated','the closing kind is stored');
reset role;

select is((select after->>'resolution_kind' from admin_audit_log where action='resolve_report' and target_id=(select id::text from fx where name='name')),
  'duplicate','the kind is audited');
select is((select note from admin_audit_log where action='resolve_report' and target_id=(select id::text from fx where name='name')),
  '已有相同名稱建議','the note is audited with it');

-- A rejection written outside the RPC (Dashboard, service role) needs a kind too.
select throws_ok($$update moderation_queue set status='rejected',resolved_at=now() where id=(select id from fx where name='access')$$,
  '22023','a rejection needs a resolution kind','a direct rejection without a kind is refused');
select lives_ok($$update moderation_queue set status='rejected',resolution_kind='insufficient',resolved_at=now() where id=(select id from fx where name='access')$$,
  'a direct rejection with a kind is accepted');
select lives_ok($$update moderation_queue set resolution_note='補充' where id=(select id from fx where name='access')$$,
  'editing an older rejection does not re-check it');
select throws_ok($$update moderation_queue set resolution_kind='later' where id=(select id from fx where name='access')$$,
  '23514',null,'the column only holds known kinds');

-- Baseline metrics: admins only.
select pg_temp.act('user');
set local role authenticated;
select throws_ok($$select * from admin_review_baseline()$$,'42501',null,'an ordinary user cannot read the baseline');
reset role;
select pg_temp.act('admin_aal1');
set local role authenticated;
select throws_ok($$select * from admin_review_baseline()$$,'42501',null,'an admin without a second factor cannot read the baseline');
reset role;
select ok(not has_function_privilege('anon','public.admin_review_baseline(int)','EXECUTE'),'anon cannot call the baseline');

-- Resolution times are pinned to the start of this Taiwan month, not to
-- now(): admin_review_baseline() buckets by Asia/Taipei month, so
-- now()-5 hours fell into last month from 00:00 to 05:00 on the 1st (#224).
-- Month start + 1–5 hours is in this month whenever the test runs (also in
-- its last hours); early on the 1st it is still ahead of now(), which the
-- baseline does not bound. Durations stay 1, 1 and 4 hours (median 1.0).
create temporary table m0 on commit drop as
  select (date_trunc('month',now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei') as t;
update moderation_queue set created_at=(select t from m0)+interval '1 hour',resolved_at=(select t from m0)+interval '2 hours'
  where id in (select id from fx where name in ('name','fee'));
update moderation_queue set created_at=(select t from m0)+interval '1 hour',resolved_at=(select t from m0)+interval '5 hours'
  where id=(select id from fx where name='guide');
select pg_temp.act('admin');
set local role authenticated;
select throws_ok($$select * from admin_review_baseline(0)$$,'22023',null,'the window must be at least a month');
select is((select count(*)::int from admin_review_baseline(3)),3,'one row per month');
create temporary table b on commit drop as select * from admin_review_baseline(1);
select is((select reports from b),18,'reports queued this month');
select is((select reporters from b),1,'distinct reporters this month');
select is((select auto_reports from b),1,'vote-triggered reports have no reporter');
select is((select resolved from b),4,'every resolution this month counts');
select is((select admin_resolved from b),3,'only RPC resolutions count as admin resolved');
select is((select median_hours from b),1.0,'median hours to an admin resolution');
select is((select by_status from b),'{"accepted":2,"rejected":2}'::jsonb,'resolutions by status');
select is((select by_resolution_kind from b),'{"duplicate":1,"outdated":1,"insufficient":1,"unclassified":1}'::jsonb,'resolutions by kind');
select is((select (by_risk->>'high')::int from b),9,'reports by risk');
reset role;

select * from finish();
rollback;
