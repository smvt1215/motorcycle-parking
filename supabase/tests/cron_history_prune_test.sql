-- pg_cron 執行紀錄清理（#183；202610310600_cron_history_prune.sql）：
-- 排程存在，只刪 end_time 早於 7 天前的紀錄。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select is((select schedule from cron.job where jobname='cron-history-prune'),'23 20 * * *',
  'runs daily at 04:23 Taiwan time');
select is((select command from cron.job where jobname='cron-history-prune'),'select public.cron_history_prune()',
  'and calls the prune');
select ok(not has_function_privilege('anon','public.cron_history_prune()','execute'),'anon cannot call it');
select ok(not has_function_privilege('authenticated','public.cron_history_prune()','execute'),'authenticated cannot call it');

-- Rehearse with a known table: only these test rows exist below.
delete from cron.job_run_details;
insert into cron.job_run_details(jobid,runid,database,username,command,status,start_time,end_time) values
  (999,-1,'postgres','postgres','select 1','succeeded',now()-interval '8 days',now()-interval '8 days'),
  (999,-2,'postgres','postgres','select 1','failed',now()-interval '7 days 1 minute',now()-interval '7 days 1 minute'),
  (999,-3,'postgres','postgres','select 1','succeeded',now()-interval '6 days',now()-interval '6 days'),
  (999,-4,'postgres','postgres','select 1','succeeded',now()-interval '1 minute',now()),
  (999,-5,'postgres','postgres','select 1','running',now()-interval '8 days',null);
select is(cron_history_prune(),2,'deletes the two runs that ended more than 7 days ago');
select is((select array_agg(runid order by runid desc) from cron.job_run_details),array[-3,-4,-5]::bigint[],
  'keeps newer runs and runs without an end time');
select is(cron_history_prune(),0,'running it again deletes nothing');

select * from finish();
rollback;
