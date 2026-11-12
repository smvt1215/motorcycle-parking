-- 檢舉通知信的連結改開管理站「待處理」的案件頁 /pending/:caseId（#449）。
-- 案件編號不一定等於檢舉編號：timed_case_rows 把同一點、同一 target 未結案的
-- 檢舉併成一案，案件 id 是組內最早一則（created_at、id 最小）的 id。所以
-- report_mail_pending 多回 case_id：寄信當下這筆檢舉所在案件的 id；這筆已結案
-- 或已不存在時為 null（信改連到待處理清單）。其餘與 202611021300 相同。
-- 案件頁結案（admin_v1.resolve_content_report）一次結掉整組，所以寄出後組內
-- 最早一則不會先單獨結案，連結一直開到同一案。

-- timed_case_rows（202611090800）reports 段的同一個分組規則，只算一筆。
create function private.report_case_id(p_id uuid) returns uuid
language sql stable security definer set search_path='' as $$
  select m.id from public.moderation_queue q
  join public.moderation_queue m on m.source_id=q.source_id and m.field='inappropriate'
    and m.resolved_at is null and m.proposed->>'target' is not distinct from q.proposed->>'target'
  where q.id=p_id and q.field='inappropriate' and q.resolved_at is null
  order by m.created_at,m.id limit 1
$$;
revoke execute on function private.report_case_id(uuid) from public,anon,authenticated,service_role;

drop function public.report_mail_pending(int);
create function public.report_mail_pending(p_limit int default 50) returns table(id uuid,kind text,case_id uuid)
language sql stable security definer set search_path='' as $$
  select n.queue_id,n.kind,private.report_case_id(n.queue_id) from private.report_notices n where n.sent_at is null
  order by n.created_at limit least(greatest(coalesce(p_limit,50),1),200)
$$;
revoke execute on function public.report_mail_pending(int) from public,anon,authenticated;
grant execute on function public.report_mail_pending(int) to service_role;
