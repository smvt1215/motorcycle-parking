-- 刪除帳號網頁的嘗試紀錄每小時清除（#463；使用者 2026-11-15 決定）。
--
-- private.deletion_precheck_attempts（IP 的 HMAC）原本只在下一次嘗試時，由
-- public.deletion_precheck_attempt() 順手刪掉 1 小時前的列
-- （202611051000_deletion_precheck.sql）；沒有人再嘗試時，最後一批會一直留著。
-- 這裡加一個每小時的排程刪掉超過 1 小時的列，原本順手刪的邏輯不變。
-- 執行紀錄由 cron-history-prune 清（7 天）。

create function public.deletion_precheck_attempts_prune() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  delete from private.deletion_precheck_attempts where created_at<now()-interval '1 hour';
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke all on function public.deletion_precheck_attempts_prune() from public,anon,authenticated,service_role;

-- 每小時第 33 分（UTC 與台灣時間的分鐘相同），避開其他排程用到的分鐘。
-- cron.schedule 以 (job_name, username) upsert，重跑只會更新同一個 job。
select cron.schedule('deletion-precheck-prune','33 * * * *','select public.deletion_precheck_attempts_prune()');
