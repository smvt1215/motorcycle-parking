-- apply_report 的每日上限（#203）：台灣日界線、每帳號 10 筆、每網路 200 筆，
-- App Check 強制後（p_ip_capped=false）網路量改為風險訊號；網路只存雜湊。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
select ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
create function pg_temp.report(n integer,body jsonb,ip text,device text,capped boolean default true) returns jsonb language sql as $$
select public.apply_report(pg_temp.uid(n),repeat(ip,64),repeat(device,64),body,capped);
$$;
create function pg_temp.flag(src text) returns jsonb language sql immutable as $$
select jsonb_build_object('action','flag','source_id',src,'reason','測試');
$$;

-- ---- 台灣日界線：台灣 0 點＝UTC 16:00。
select is((report_day_start() at time zone 'Asia/Taipei')::time,'00:00'::time,'the day starts at midnight in Taiwan');
select is((report_day_start() at time zone 'UTC')::time,'16:00'::time,'which is 16:00 UTC');
select ok(report_day_start()<=now() and report_day_start()>now()-interval '1 day','the day start is the latest Taiwan midnight');

-- Ten events just before the Taiwan midnight (UTC 15:59:59) are yesterday's.
delete from rate_limit_events;
insert into rate_limit_events(user_id,ip_hash,created_at)
  select pg_temp.uid(2),repeat('a',64),report_day_start()-interval '1 second' from generate_series(1,10);
select lives_ok($$select pg_temp.report(2,pg_temp.flag('official:t1'),'b','b')$$,'reports before UTC 16:00 count for the previous Taiwan day');
-- Ten at the midnight itself (UTC 16:00) are today's.
delete from rate_limit_events;
insert into rate_limit_events(user_id,ip_hash,created_at)
  select pg_temp.uid(2),repeat('a',64),report_day_start() from generate_series(1,10);
select throws_ok($$select pg_temp.report(2,pg_temp.flag('official:t2'),'b','b')$$,'P0001','daily report limit reached',
  'reports from UTC 16:00 count for the new Taiwan day');

-- ---- 每帳號每日 10 筆，App Check 強制後仍然硬擋。
delete from rate_limit_events;
do $$begin for n in 1..10 loop perform pg_temp.report(6,pg_temp.flag('official:a'||n),'c','c');end loop;end$$;
select throws_ok($$select pg_temp.report(6,pg_temp.flag('official:a11'),'d','d')$$,'P0001','daily report limit reached','ten per account a day');
select throws_ok($$select pg_temp.report(6,pg_temp.flag('official:a12'),'d','d',false)$$,'P0001','daily report limit reached',
  'the account limit holds once App Check is enforced');

-- ---- 每網路每日 200 筆（只記錄期間）。
delete from rate_limit_events;
insert into rate_limit_events(user_id,ip_hash,created_at)
  select pg_temp.uid(5),repeat('e',64),report_day_start() from generate_series(1,199);
select lives_ok($$select pg_temp.report(7,pg_temp.flag('official:n1'),'e','e')$$,'the 200th report from a network is accepted');
select throws_ok($$select pg_temp.report(7,pg_temp.flag('official:n2'),'e','e')$$,'P0001','daily report limit reached',
  'the 201st is refused while App Check only logs');
select is((select count(*)::integer from rate_limit_events where ip_busy),0,'nothing is marked while the cap holds');

-- ---- p_ip_capped=false：照收、標記 ip_busy、送審或降權。
select lives_ok($$select pg_temp.report(7,pg_temp.flag('official:n3'),'e','e',false)$$,'past 200 the report is kept once App Check is enforced');
select is((select ip_busy from rate_limit_events where user_id=pg_temp.uid(7) order by id desc limit 1),true,'the event is marked ip_busy');
select ok((select 'ip_busy'=any(risk_flags) from moderation_queue where source_id='official:n3'),'the flag reaches review with the ip_busy risk flag');
select ok((select not ('ip_busy'=any(risk_flags)) from moderation_queue where source_id='official:n1'),'a report under the cap carries no ip_busy flag');

create temporary table busy_spot as select (pg_temp.report(2,'{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"忙碌網路點","lat":25.031,"lng":121.531,"city":"臺北市","space_type":"paidMotorcycle"}}','e','f',false)->>'id')::uuid as id;
select ok((select 'ip_busy'=any(risk_flags) from moderation_queue where source_id=(select id::text from busy_spot) and field='create'),
  'a new spot from a busy network opens a review case');
select pg_temp.report(1,'{"action":"create","spot":{"scooter_allowed":true,"heavy_allowed":true,"name":"一般點","lat":25.041,"lng":121.541,"city":"臺北市","space_type":"paidMotorcycle"}}','g','g');
select pg_temp.report(6,jsonb_build_object('action','vote','spot_id',(select id from community_spots where name='一般點'),'vote','still_there'),'e','h',false);
select is((select qualified from spot_votes where user_id=pg_temp.uid(6) and spot_id=(select id from community_spots where name='一般點')),false,
  'a vote from a busy network counts as unqualified');

-- ---- 網路只存雜湊。
select throws_ok($$select public.apply_report(pg_temp.uid(2),'203.0.113.7',repeat('d',64),pg_temp.flag('official:raw'))$$,'22023','missing trusted identity',
  'a raw IP is refused');
select is((select array_agg(column_name::text order by column_name::text) from information_schema.columns
  where table_schema='public' and table_name='rate_limit_events'),array['created_at','id','ip_busy','ip_hash','user_id'],
  'rate_limit_events keeps only the network hash');
select is((select count(*)::integer from rate_limit_events where char_length(ip_hash)<>64),0,'every stored network is a 64-character hash');

-- ---- 權限。
select ok(to_regprocedure('public.apply_report(uuid,text,text,jsonb)') is null,'the four-argument apply_report is gone');
select ok(not has_function_privilege('anon','public.apply_report(uuid,text,text,jsonb,boolean)','EXECUTE')
  and not has_function_privilege('authenticated','public.apply_report(uuid,text,text,jsonb,boolean)','EXECUTE'),'riders cannot call apply_report');
select ok(has_function_privilege('service_role','public.apply_report(uuid,text,text,jsonb,boolean)','EXECUTE'),'the Edge Function can');
select ok(not has_function_privilege('anon','public.report_day_start()','EXECUTE')
  and not has_function_privilege('authenticated','public.report_day_start()','EXECUTE'),'the day helper is internal');

select * from finish();
rollback;
