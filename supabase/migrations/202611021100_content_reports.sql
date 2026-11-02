-- #280 第 2 層：內容不當檢舉（使用者決定 PM_ASSIGN_20261102_161；提案
-- t280-proposal.md 第 2 節）。暫時隱藏是第 3 層。
--
-- submit-report 的 flag，field 'inappropriate'，proposed {target}：
--   target ∈ rider_name、spot_name、text、impersonation、other；other 時 note
--   必填；note 最多 500 字（moderation_queue 既有約束）。
-- 1. 只能檢舉社群點（車友新增、管理員新增或匯入、已匿名化都可以）；官方點
--    與自己的點不行。登入、每日上限、App Check 沿用 apply_report。
-- 2. 同一人對同一點只能有一筆處理中：重複回 P0409（submit-report → 409
--    duplicate report）。既有的 (source_id,reason) 去重不適用檢舉：兩個人
--    送出相同摘要，第二筆會被 on conflict do nothing 默默吃掉。
-- 3. 檢舉當下的名稱、說明與入口文字由既有的 moderation_base_version 觸發器
--    從資料表快照進 base_spot，不信 client；proposed 只留 target。
-- 4. 新檢舉通知 ops@：同交易寫 private.report_notices，pg_cron（與寫入當下）
--    叫 Edge Function report-mail 寄信，只含編號與管理站連結；寄信失敗
--    不影響檢舉，下次排程重試。

-- ===== 1. 去重 =====
drop index public.moderation_unresolved_idx;
create unique index moderation_unresolved_idx on public.moderation_queue(source_id,reason)
  where resolved_at is null and field is distinct from 'inappropriate';
create unique index moderation_inappropriate_open_idx on public.moderation_queue(source_id,reporter_id)
  where resolved_at is null and field='inappropriate';

-- ===== 2. 檢舉的規則（apply_report 寫入時；validate.ts、precheck 也檢查） =====
create function private.inappropriate_targets() returns text[]
language sql immutable security definer set search_path='' as $$
  select array['rider_name','spot_name','text','impersonation','other']
$$;
revoke execute on function private.inappropriate_targets() from public,anon,authenticated,service_role;

create function public.moderation_inappropriate_check() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_owner uuid; v_found boolean;
begin
  if new.field is distinct from 'inappropriate' then return new; end if;
  if new.reporter_id is null then
    raise exception 'a report needs its reporter' using errcode='22023';
  end if;
  if new.source_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'only community spots can be reported' using errcode='22023';
  end if;
  select true,s.user_id into v_found,v_owner from public.community_spots s
    where s.id=new.source_id::uuid and s.status<>'hidden' and s.deleted_at is null;
  if v_found is null then raise exception 'spot not found' using errcode='22023'; end if;
  if v_owner is not distinct from new.reporter_id then
    raise exception 'cannot report own spot' using errcode='42501';
  end if;
  if jsonb_typeof(new.proposed) is distinct from 'object'
     or (select array_agg(k) from jsonb_object_keys(new.proposed) k)<>array['target']
     or not (new.proposed->>'target')=any(private.inappropriate_targets()) then
    raise exception 'invalid report target' using errcode='22023';
  end if;
  if new.proposed->>'target'='other' and btrim(new.note)='' then
    raise exception 'other needs a note' using errcode='22023';
  end if;
  if exists(select 1 from public.moderation_queue q where q.source_id=new.source_id
      and q.reporter_id=new.reporter_id and q.field='inappropriate' and q.resolved_at is null) then
    raise exception 'duplicate report' using errcode='P0409';
  end if;
  -- Client text beyond the target is never kept as a value to apply.
  new.evidence_url:=null;
  return new;
end;
$$;
revoke execute on function public.moderation_inappropriate_check() from public,anon,authenticated,service_role;
create trigger moderation_inappropriate_check before insert on public.moderation_queue
  for each row execute function public.moderation_inappropriate_check();

-- ===== 3. 通知信（Edge Function report-mail） =====
create table private.report_notices (
  queue_id uuid primary key references public.moderation_queue(id) on delete cascade,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index report_notices_unsent_idx on private.report_notices(created_at) where sent_at is null;
revoke all on private.report_notices from public,anon,authenticated,service_role;

-- 有待寄的通知時叫 report-mail；vault 沒有 project_url 或 report_mail_secret
-- 時不做事（由下次排程再試）。pg_net 在交易提交後才送出。
create function public.report_mail_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text;
begin
  if not exists(select 1 from private.report_notices n where n.sent_at is null) then return null; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='report_mail_secret';
  if v_url is null or v_secret is null or v_url !~ '^https://' then return null; end if;
  return net.http_post(
    url:=rtrim(v_url,'/')||'/functions/v1/report-mail',
    headers:=jsonb_build_object('Content-Type','application/json','x-report-mail-secret',v_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=60000);
end $$;
revoke all on function public.report_mail_tick() from public,anon,authenticated;

create function public.moderation_report_notice() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.field='inappropriate' then
    insert into private.report_notices(queue_id) values(new.id) on conflict do nothing;
    perform public.report_mail_tick();
  end if;
  return null;
end;
$$;
revoke execute on function public.moderation_report_notice() from public,anon,authenticated,service_role;
create trigger moderation_report_notice after insert on public.moderation_queue
  for each row execute function public.moderation_report_notice();

-- report-mail 讀待寄的編號、寄出後標記（service role）。只有編號，不含
-- 檢舉內容、點位或任何人的資料。
create function public.report_mail_pending(p_limit int default 50) returns table(id uuid)
language sql stable security definer set search_path='' as $$
  select n.queue_id from private.report_notices n where n.sent_at is null
  order by n.created_at limit least(greatest(coalesce(p_limit,50),1),200)
$$;
revoke execute on function public.report_mail_pending(int) from public,anon,authenticated;
grant execute on function public.report_mail_pending(int) to service_role;

create function public.report_mail_sent(p_id uuid) returns void
language sql security definer set search_path='' as $$
  update private.report_notices set sent_at=now() where queue_id=p_id and sent_at is null;
  -- 寄出 30 天後不必再留。
  delete from private.report_notices where sent_at<now()-interval '30 days';
$$;
revoke execute on function public.report_mail_sent(uuid) from public,anon,authenticated;
grant execute on function public.report_mail_sent(uuid) to service_role;

select cron.schedule('report-mail','*/5 * * * *','select public.report_mail_tick()');
