begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Claims for: an admin who passed MFA, the same admin before MFA, and an ordinary user.
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'admin_aal1' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal1","app_metadata":{"role":"admin"}}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
end,true);
$$;

create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000001','審核測試點',25.031,121.551,'臺北市','paidMotorcycle') returning id) insert into fx select 'spot',id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date)
  values('審核測試官方點',25.032,121.552,'臺北市','https://example.test/notice',current_date) returning id) insert into fx select 'official',id from s;
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed)
  values((select id::text from fx where name='spot'),'10000000-0000-4000-8000-000000000002','格位類型：建議「重機專用格」','格位類型','{"space_type":"heavyOnly"}') returning id) insert into fx select 'q_type',id from s;
with s as (insert into moderation_queue(source_id,reporter_id,reason)
  values('official:'||(select id from fx where name='official'),'10000000-0000-4000-8000-000000000002','收費資訊：每次 30 元') returning id) insert into fx select 'q_official',id from s;
with s as (insert into moderation_queue(source_id,reason)
  values((select id::text from fx where name='spot'),'名稱：測試駁回') returning id) insert into fx select 'q_reject',id from s;
with s as (insert into moderation_queue(source_id,reason)
  values((select id::text from fx where name='spot'),'點位已不存在：格位已撤除') returning id) insert into fx select 'q_gone',id from s;
with s as (insert into moderation_queue(source_id,reason)
  values('official:legacy','Dashboard 結案') returning id) insert into fx select 'q_legacy',id from s;

-- Who counts as an admin.
select pg_temp.act('admin');
set local role authenticated;
select ok(public.is_admin(),'admin with a second factor is admin');
reset role;
select pg_temp.act('admin_aal1');
set local role authenticated;
select ok(not public.is_admin(),'admin role without a second factor is not admin');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_type'),'accepted')$$,'42501',null,'admin without a second factor cannot resolve');
select throws_ok($$update city_rules_data set version=version+1 where city='臺北市' and vehicle='heavy'$$,'42501',null,'rules are not written directly, with or without a second factor');
reset role;
select is((select version from city_rules where city='臺北市' and vehicle='heavy'),1,'but changes no rule');
select pg_temp.act('user');
set local role authenticated;
select ok(not public.is_admin(),'ordinary user is not admin');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_type'),'accepted')$$,'42501',null,'ordinary user cannot resolve');
select is((select count(*)::integer from moderation_queue),0,'ordinary user cannot read the queue');
select is((select count(*)::integer from admin_audit_log),0,'ordinary user cannot read the audit log');
reset role;
select ok(not has_function_privilege('anon','public.admin_resolve_report(uuid,text,jsonb,text,boolean,text)','EXECUTE'),'anon cannot call the resolve RPC');

-- Accepting applies the patch and closes the report together.
select pg_temp.act('admin');
set local role authenticated;
select ok((select count(*) from moderation_queue)>=5,'admin reads the queue');
select is(admin_resolve_report((select id from fx where name='q_type'),'accepted','{"space_type":"heavyOnly","heavy_allowed":true}','比對街景')->>'status','accepted','admin accepts a suggestion');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_type'),'accepted')$$,'22023','report already resolved','a report resolves once');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_reject'),'rejected','{"name":"x"}',p_resolution_kind=>'wrong')$$,'22023','a rejected report changes no spot','a rejection cannot carry a patch');
select is(admin_resolve_report((select id from fx where name='q_reject'),'rejected',null,'與現場不符',p_resolution_kind=>'wrong')->>'status','rejected','admin rejects a suggestion');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_official'),'accepted','{"user_id":"10000000-0000-4000-8000-000000000005"}')$$,'22023',null,'columns outside the editable list are refused');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_official'),'accepted','{"status":"hidden"}')$$,'22023',null,'official spots have no status to change');
select throws_ok($$select admin_resolve_report((select id from fx where name='q_official'),'accepted','{"lat":0}')$$,'23514',null,'patched values still meet table constraints');
select is((select status from moderation_queue where id=(select id from fx where name='q_official')),'pending','a failed patch leaves the report pending');
select is(admin_resolve_report((select id from fx where name='q_official'),'accepted','{"fee_note":"每次 30 元"}')->'spot'->>'fee_note','每次 30 元','official spot patch returns the new row');
select is(admin_resolve_report((select id from fx where name='q_gone'),'accepted','{"status":"hidden"}')->'spot'->>'status','hidden','a community spot can be hidden');
select is((select count(*)::integer from community_spots where id=(select id from fx where name='spot')),1,'admin still sees the hidden spot');
select ok((select count(*) from admin_audit_log where action='resolve_report')=4,'every resolution is audited');
reset role;

select is((select space_type from community_spots where id=(select id from fx where name='spot')),'heavyOnly','accepted patch reached the spot');
select is((select heavy_allowed from community_spots where id=(select id from fx where name='spot')),true,'patch sets booleans');
select is((select name from community_spots where id=(select id from fx where name='spot')),'審核測試點','fields outside the patch are kept');
select is((select fee_note from official_heavy_spots where id=(select id from fx where name='official')),'每次 30 元','official spot updated');
select is((select resolved_by from moderation_queue where id=(select id from fx where name='q_type')),'10000000-0000-4000-8000-000000000005'::uuid,'resolver recorded');
select ok((select resolved_at is not null and resolution_note='比對街景' from moderation_queue where id=(select id from fx where name='q_type')),'resolution time and note recorded');
select is((select before->'spot'->>'space_type' from admin_audit_log where target_id=(select id::text from fx where name='q_type')),'paidMotorcycle','audit keeps the old value');
select is((select after->'spot'->>'space_type' from admin_audit_log where target_id=(select id::text from fx where name='q_type')),'heavyOnly','audit keeps the new value');
select ok((select not (before->'spot' ? 'user_id') from admin_audit_log where target_id=(select id::text from fx where name='q_type')),'audit omits contributor ids');
set local role anon;
select is((select count(*)::integer from community_spots where id=(select id from fx where name='spot')),0,'the public no longer sees a hidden spot');
reset role;

-- Restoring a spot hidden by votes discards the votes that hid it.
insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
select (select id from fx where name='spot'),u::uuid,v,true,1,repeat(h,64),repeat(h,64)
from (values('10000000-0000-4000-8000-000000000002','gone','m'),('10000000-0000-4000-8000-000000000003','gone','n'),
  ('10000000-0000-4000-8000-000000000006','gone','o'),('10000000-0000-4000-8000-000000000007','still_there','p')) x(u,v,h);
with s as (insert into moderation_queue(source_id,reason) values((select id::text from fx where name='spot'),'恢復顯示：格位仍在') returning id)
insert into fx select 'q_restore',id from s;
select pg_temp.act('admin');
set local role authenticated;
select is(admin_resolve_report((select id from fx where name='q_restore'),'accepted','{"status":"pending"}')->'spot'->>'status','pending','admin restores a hidden spot');
reset role;
select is((select count(*)::integer from spot_votes where spot_id=(select id from fx where name='spot') and vote='gone'),0,'restoring clears the gone votes');
select is((select count(*)::integer from spot_votes where spot_id=(select id from fx where name='spot') and vote='still_there'),1,'restoring keeps still-there votes');
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('q',64),repeat('q',64),
  jsonb_build_object('action','vote','spot_id',(select id from fx where name='spot'),'vote','still_there'));
select isnt((select status from community_spots where id=(select id from fx where name='spot')),'hidden','a later vote does not hide the restored spot again');

-- The audit log is append-only, even for the table owner.
select throws_ok($$update admin_audit_log set note='x'$$,'42501','audit log entries cannot be changed','audit entries cannot be edited');
select throws_ok($$delete from admin_audit_log$$,'42501','audit log entries cannot be changed','audit entries cannot be deleted');
select throws_ok($$truncate admin_audit_log$$,'42501','audit log entries cannot be changed','audit log cannot be truncated');

-- Dashboard resolution still works and leaves the admin queue.
update moderation_queue set resolved_at=now() where id=(select id from fx where name='q_legacy');
select is((select status from moderation_queue where id=(select id from fx where name='q_legacy')),'closed','resolving in the Dashboard closes the report');

-- Reports carry the structured suggestion.
delete from rate_limit_events;
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('s',64),repeat('s',64),
  jsonb_build_object('action','flag','source_id','official:'||(select id from fx where name='official'),
    'reason','位置：建議移動','field','位置','proposed',jsonb_build_object('lat',25.0321,'lng',121.5521),'note','入口在巷內'));
select is((select field from moderation_queue where reason='位置：建議移動'),'位置','flag stores the field');
select is((select (proposed->>'lat')::numeric from moderation_queue where reason='位置：建議移動'),25.0321,'flag stores the proposed value');
select is((select note from moderation_queue where reason='位置：建議移動'),'入口在巷內','flag stores the note');
select is((select status from moderation_queue where reason='位置：建議移動'),'pending','a new flag is pending');
select public.apply_report('10000000-0000-4000-8000-000000000002',repeat('t',64),repeat('t',64),
  jsonb_build_object('action','flag','source_id','official:plain','reason','舊版 App 的建議'));
select ok((select field is null and proposed is null and note='' from moderation_queue where reason='舊版 App 的建議'),'flags from older apps still work');

select * from finish();
rollback;
