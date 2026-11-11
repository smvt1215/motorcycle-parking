-- 過期的停權列定期清除（#338，#332 後續）。使用者決定（2026-11-11）：
-- private.user_suspensions 中「到期超過 90 天」的列併入每日的 account_data_retention。
--   * 只刪 until 有值且 until < now()-90 天 的列。無限期（until is null）、尚未到期、
--     到期未滿 90 天的列都不動。過期的列本來就視為未停權（is_suspended 看 until>now()）。
--   * 停權的查證紀錄是 admin_audit_log 的 ban_user／unban_user（保留 2 年後去識別化），
--     清除這些列不影響查證；其他清除項目（usage_events、support_requests 等）也不另寫稽核，
--     照辦。
--   * 與 private.suspension_carryover（帳號刪除後為維持停權保留的身分雜湊，無限期最多 180 天）
--     是不同的表、不同的清除函式（suspension_carryover_prune）；本次不改它。
--   * 其餘與 202611090200_suspension_carryover.sql 的 account_data_retention 相同。

create function private.retention_expired_suspensions() returns interval
language sql immutable security definer set search_path='' as $$ select interval '90 days' $$;
revoke execute on function private.retention_expired_suspensions() from public,anon,authenticated,service_role;

create function public.user_suspensions_prune() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  delete from private.user_suspensions s
    where s.until is not null and s.until<now()-private.retention_expired_suspensions();
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke execute on function public.user_suspensions_prune() from public,anon,authenticated,service_role;

create or replace function public.account_data_retention() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  return jsonb_build_object(
    'usage_events',public.usage_events_prune(),
    'anonymized_hashes',public.anonymized_hashes_clear(),
    'support_requests',public.support_requests_prune(),
    'suspension_carryover',public.suspension_carryover_prune(),
    'user_suspensions',public.user_suspensions_prune(),
    'audit_log',public.admin_audit_deidentify());
end $$;
