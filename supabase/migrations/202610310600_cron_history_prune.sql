-- pg_cron 執行紀錄定期清理（#183）。
-- cron.job_run_details 不會自動清理，unschedule 後也不會刪；availability-ingest
-- 每分鐘一次（202610310500），每天約多 1,150 筆。pg_cron 與 Supabase 文件都
-- 建議以 pg_cron 自己每天刪掉 7 天前的紀錄。
-- 包成 security definer 函式（擁有者為執行 migration 的 postgres，與排程的
-- 執行身分相同），方便測試並與其他排程寫法一致；不開放給 API 角色。
create function public.cron_history_prune() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  delete from cron.job_run_details where end_time<now()-interval '7 days';
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke all on function public.cron_history_prune() from public,anon,authenticated;

-- cron 以 UTC 表示：20:23 UTC＝台灣 04:23（UTC+8），避開整點與其他排程的分鐘。
-- cron.schedule 以 (job_name, username) upsert，重跑只會更新同一個 job。
select cron.schedule('cron-history-prune','23 20 * * *','select public.cron_history_prune()');
