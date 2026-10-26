begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

-- Rider 2 is "me"; rider 6 is someone else; 5 is an admin.
create function pg_temp.act(who text) returns void language sql as $$
select set_config('request.jwt.claims',case who
  when 'other' then '{"sub":"10000000-0000-4000-8000-000000000006","role":"authenticated","aal":"aal1","app_metadata":{"role":"user"}}'
  when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
  when 'nobody' then '{"role":"authenticated"}'
  else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1","app_metadata":{"role":"user"}}'
end,true);
$$;

create temporary table fx(name text primary key,id uuid);
grant select on fx to authenticated,anon;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date)
  values('我的官方點',25.051,121.571,'臺北市','https://example.test/notice',current_date) returning id) insert into fx select 'official',id from s;
with s as (insert into official_heavy_spots(name,lat,lng,city,source_url,effective_date,hidden)
  values('已隱藏官方點',25.052,121.572,'臺北市','https://example.test/notice',current_date,true) returning id) insert into fx select 'official_hidden',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,created_at)
  values('10000000-0000-4000-8000-000000000002','我新增的點',25.053,121.573,'臺北市','paidMotorcycle',now()-interval '5 days') returning id) insert into fx select 'mine_spot',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type,status,created_at)
  values('10000000-0000-4000-8000-000000000002','我新增但被隱藏',25.054,121.574,'臺北市','paidMotorcycle','hidden',now()-interval '4 days') returning id) insert into fx select 'mine_hidden',id from s;
with s as (insert into community_spots(user_id,name,lat,lng,city,space_type)
  values('10000000-0000-4000-8000-000000000006','別人的點',25.055,121.575,'臺北市','paidMotorcycle') returning id) insert into fx select 'other_spot',id from s;

-- My reports: a pending name suggestion on an official spot, an accepted
-- one on someone else's community spot, a rejected gone report on a hidden
-- official spot, and one on an id from a retired source.
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,proposed,created_at)
  values('official:'||(select id from fx where name='official'),'10000000-0000-4000-8000-000000000002','停車點名稱：新名稱','name','{"name":"新名稱"}',now()-interval '3 days') returning id) insert into fx select 'q_pending',id from s;
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,created_at)
  values((select id from fx where name='other_spot')::text,'10000000-0000-4000-8000-000000000002','其他備註：入口在右邊','note',now()-interval '2 days') returning id) insert into fx select 'q_accepted',id from s;
update moderation_queue set status='accepted',resolved_at=now(),resolved_by='10000000-0000-4000-8000-000000000005',resolution_note='內部：已電話確認'
  where id=(select id from fx where name='q_accepted');
insert into admin_audit_log(actor,action,target_table,target_id,after)
  values('10000000-0000-4000-8000-000000000005','resolve_report','moderation_queue',(select id from fx where name='q_accepted')::text,
    jsonb_build_object('status','accepted','spot',jsonb_build_object('name','別人的點')));
-- 結案不修改: accepted with an empty patch, audited without a spot.
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,created_at)
  values('official:'||(select id from fx where name='official'),'10000000-0000-4000-8000-000000000002','其他備註：只是提醒','note',now()-interval '7 days') returning id) insert into fx select 'q_closed_nochange',id from s;
update moderation_queue set status='accepted',resolved_at=now(),resolution_kind='duplicate' where id=(select id from fx where name='q_closed_nochange');
insert into admin_audit_log(actor,action,target_table,target_id,after)
  values('10000000-0000-4000-8000-000000000005','resolve_report','moderation_queue',(select id from fx where name='q_closed_nochange')::text,
    jsonb_build_object('status','accepted','spot',null));
with s as (insert into moderation_queue(source_id,reporter_id,reason,field,created_at)
  values('official:'||(select id from fx where name='official_hidden'),'10000000-0000-4000-8000-000000000002','這裡已經不能停車：格線已撤除','gone',now()-interval '1 day') returning id) insert into fx select 'q_rejected',id from s;
update moderation_queue set status='rejected',resolved_at=now(),resolution_kind='outdated',resolution_note='內部：重複' where id=(select id from fx where name='q_rejected');
with s as (insert into moderation_queue(source_id,reporter_id,reason,created_at)
  values('tdx:retired-1','10000000-0000-4000-8000-000000000002','舊回報',now()-interval '6 days') returning id) insert into fx select 'q_retired',id from s;
-- Someone else's report on my spot, and an unattributed vote-threshold row.
insert into moderation_queue(source_id,reporter_id,reason,field)
  values((select id from fx where name='mine_spot')::text,'10000000-0000-4000-8000-000000000006','其他備註：別人的建議','note');
insert into moderation_queue(source_id,reason) values((select id from fx where name='mine_spot')::text,'加權負向回報達門檻');
-- The hidden official spot was renamed after the report: I keep seeing what I reported.
update moderation_queue set base_spot=jsonb_set(base_spot,'{name}','"我回報時的名稱"') where id=(select id from fx where name='q_rejected');
update official_heavy_spots set name='管理員改過的名稱' where id=(select id from fx where name='official_hidden');

-- anon and callers without a user are refused.
set local role anon;
select throws_ok($$select * from my_contributions()$$,'42501',null,'anon cannot call my_contributions');
reset role;
select pg_temp.act('nobody');
set local role authenticated;
select throws_ok($$select * from my_contributions()$$,'42501',null,'a token without a user is refused');
-- Riders still cannot read the queue directly.
select pg_temp.act('me');
select is((select count(*) from moderation_queue)::int,0,'riders read no queue rows directly');

select is((select count(*) from my_contributions())::int,7,'I see my five reports and two spots');
select is((select string_agg(id,',' order by created_at desc) from my_contributions()),
  (select string_agg(x,',') from (select (select id from fx where name=n)::text x from unnest(array['q_rejected','q_accepted','q_pending','mine_hidden','mine_spot','q_retired','q_closed_nochange']) with ordinality u(n,o) order by o) y),
  'newest first');
select ok(not exists(select 1 from my_contributions() where summary like '%別人的建議%' or summary='加權負向回報達門檻'),
  'reports by others or by vote thresholds on my spot are not mine');
select ok(not exists(select 1 from my_contributions() where spot_id=(select id from fx where name='other_spot')::text and kind='new_spot'),
  'spots other riders added are not mine');

select is((select kind||'|'||status||'|'||spot_name||'|'||field||'|'||summary||'|'||spot_visible from my_contributions() where id=(select id from fx where name='q_pending')::text),
  'report|pending|我的官方點|name|停車點名稱：新名稱|true','a pending suggestion shows the spot and my summary');
select is((select spot_id from my_contributions() where id=(select id from fx where name='q_pending')::text),
  'official:'||(select id from fx where name='official'),'official reports keep the app id');
select is((select status||'|'||spot_name||'|'||lat from my_contributions() where id=(select id from fx where name='q_accepted')::text),
  'accepted|別人的點|25.055','an accepted suggestion on a public community spot comes with coordinates');
select is((select status||'|'||spot_name||'|'||spot_visible||'|'||coalesce(lat::text,'none')||'|'||(resolved_at is not null) from my_contributions() where id=(select id from fx where name='q_rejected')::text),
  'rejected|我回報時的名稱|false|none|true','a hidden spot shows the reported name, no coordinates and no later edits');
select is((select resolution_kind from my_contributions() where id=(select id from fx where name='q_rejected')::text),
  'outdated','a rejection says which kind it was');
select is((select status||'|'||resolution_kind from my_contributions() where id=(select id from fx where name='q_closed_nochange')::text),
  'closed|duplicate','an accepted report closed without changing the spot reads as closed');
select is((select count(*) from my_contributions() where resolution_kind is not null)::int,2,
  'only rejected or closed reports carry a kind');
select is((select coalesce(spot_name,'none')||'|'||spot_visible from my_contributions() where id=(select id from fx where name='q_retired')::text),
  'none|false','a report on a retired source has no spot');
select is((select status||'|'||spot_name||'|'||spot_visible from my_contributions() where id=(select id from fx where name='mine_hidden')::text),
  'hidden|我新增但被隱藏|false','my hidden spot is listed as hidden');
select is((select kind||'|'||status||'|'||spot_visible||'|'||coalesce(summary,'none') from my_contributions() where id=(select id from fx where name='mine_spot')::text),
  'new_spot|pending|true|none','my new spot is listed as pending');

-- Nothing that identifies anyone or the admin's internal note.
select ok(not exists(select 1 from (select to_jsonb(m) j from my_contributions() m) x
    where j::text like '%10000000-0000-4000-8000-00000000000%' or j::text like '%內部%' or j ? 'reporter_id' or j ? 'resolution_note' or j ? 'resolved_by' or j ? 'ip_hash'),
  'no reporter, resolver, IP or internal note is returned');

-- Pages: keyed by (created_at,id), bounded.
select is((select count(*) from my_contributions(null,null,2))::int,2,'a page holds the requested size');
select is((select string_agg(id,',' order by created_at desc) from my_contributions(
    (select created_at from my_contributions(null,null,2) order by created_at limit 1),
    (select id from my_contributions(null,null,2) order by created_at limit 1),2)),
  (select id from fx where name='q_pending')::text||','||(select id from fx where name='mine_hidden')::text,'the next page continues after the cursor');
select is((select count(*) from my_contributions(null,null,0))::int,1,'the page size is at least 1');
reset role;
insert into moderation_queue(source_id,reporter_id,reason,created_at)
  select 'tdx:bulk','10000000-0000-4000-8000-000000000002','大量回報 '||g,now()-interval '30 days'-g*interval '1 minute' from generate_series(1,60) g;
set local role authenticated;
select is((select count(*) from my_contributions(null,null,1000))::int,50,'a page holds at most 50 rows');
select throws_ok($$select * from my_contributions(now(),null)$$,'22023',null,'a half cursor is refused');

-- Someone else sees only their own rows.
select pg_temp.act('other');
select is((select string_agg(kind||':'||spot_name,',' order by kind) from my_contributions()),'new_spot:別人的點,report:我新增的點',
  'another rider sees only their own spot and report');
select ok(not exists(select 1 from my_contributions() where summary like '%新名稱%' or summary like '%入口在右邊%'),
  'another rider never sees my reports');
-- Admins get their own list too, not everyone's.
select pg_temp.act('admin');
select is((select count(*) from my_contributions())::int,0,'admins see only what they sent themselves');
reset role;

select * from finish();
rollback;
