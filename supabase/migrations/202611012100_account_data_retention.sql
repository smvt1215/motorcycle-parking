-- 帳號相關資料定期清除（#267；使用者決定 2026-11-01）：
--   1. 只用來防濫用、不影響地圖資料的使用紀錄保留 30 天：rate_limit_events
--      （回報限流）、geocode_events（地址查詢限流）。限流與管理站統計的
--      時間窗都在 30 天內（當天、7 天、30 天），刪掉更舊的列不影響。
--      rider_sightings 原本就 7 天刪除（rider-sightings-prune），不重複處理。
--   2. 刪除帳號（#215 的 anonymized_at）滿 180 天後，匿名保留的投票、
--      回報（新增點位的 report_identities）與目擊上的 ip_hash／device_hash
--      清成固定值 64 個 0（欄位 not null、目擊有長度 64 的約束；HMAC 不會
--      產生全 0，新的投票或回報永遠不會和它相同）。
--   3. admin_audit_log 滿 2 年去識別化：target_table 是 auth.users 時拿掉
--      target_id 的 uid，before／after 拿掉個資鍵、貢獻者名稱換成固定文字；
--      actor（管理員本人）照留。不可修改的觸發器只放行「把一列改成它的
--      去識別化結果」這一種修改，其他修改、刪除、truncate 仍然禁止；每次
--      去識別化另寫一筆稽核。
--   4. 每日一個 pg_cron（台灣 04:29）依序執行，客服申請結案 180 天刪除
--      （202611012000，原本獨立排程）一併併入。

-- ===== 0. 期限與固定值 =====
create function private.retention_usage_events() returns interval
language sql immutable security definer set search_path='' as $$ select interval '30 days' $$;
create function private.retention_anonymized_hashes() returns interval
language sql immutable security definer set search_path='' as $$ select interval '180 days' $$;
create function private.retention_audit_log() returns interval
language sql immutable security definer set search_path='' as $$ select interval '2 years' $$;
-- 清除後的雜湊。
create function private.retention_cleared_hash() returns text
language sql immutable security definer set search_path='' as $$ select repeat('0',64) $$;
revoke execute on function private.retention_usage_events(),private.retention_anonymized_hashes(),
  private.retention_audit_log(),private.retention_cleared_hash()
  from public,anon,authenticated,service_role;

-- ===== 1. 使用紀錄 30 天 =====
-- 每日依 created_at 刪除；原本只有 (user_id,created_at) 與 (ip_hash,created_at)。
create index rate_limit_events_created_idx on public.rate_limit_events(created_at);

create function public.usage_events_prune() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_cut timestamptz:=now()-private.retention_usage_events();
  v_rate integer; v_geocode integer;
begin
  delete from public.rate_limit_events r where r.created_at<v_cut;
  get diagnostics v_rate=row_count;
  delete from public.geocode_events g where g.created_at<v_cut;
  get diagnostics v_geocode=row_count;
  return jsonb_build_object('rate_limit_events',v_rate,'geocode_events',v_geocode);
end $$;
revoke execute on function public.usage_events_prune() from public,anon,authenticated;

comment on table public.rate_limit_events is
  '回報限流紀錄：只防濫用，30 天後由 usage_events_prune() 刪除（#267）。';
comment on table public.geocode_events is
  '地址查詢限流紀錄：只防濫用，30 天後由 usage_events_prune() 刪除（#267）。';

-- ===== 2. 刪帳號後的雜湊 180 天 =====
-- 只動雜湊欄位：投票的 spot_votes_history 觸發器只看 vote／created_at，
-- mark_anonymized 只看 user_id，都不會被觸發。
create function public.anonymized_hashes_clear() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_cut timestamptz:=now()-private.retention_anonymized_hashes();
  v_zero text:=private.retention_cleared_hash();
  v_votes integer; v_spots integer; v_sightings integer;
begin
  update public.spot_votes v set ip_hash=v_zero,device_hash=v_zero
    where v.anonymized_at<v_cut and (v.ip_hash<>v_zero or v.device_hash<>v_zero);
  get diagnostics v_votes=row_count;
  -- 新增點位的回報者雜湊；點位的 anonymized_at 是回報者刪帳號的時間。
  update public.report_identities r set ip_hash=v_zero,device_hash=v_zero
    from public.community_spots c
    where c.id=r.spot_id and c.anonymized_at<v_cut and (r.ip_hash<>v_zero or r.device_hash<>v_zero);
  get diagnostics v_spots=row_count;
  -- 目擊 7 天就刪，正常不會留到這裡；保險起見一併處理。
  update public.rider_sightings s set ip_hash=v_zero,device_hash=v_zero
    where s.anonymized_at<v_cut and (s.ip_hash<>v_zero or s.device_hash<>v_zero);
  get diagnostics v_sightings=row_count;
  return jsonb_build_object('spot_votes',v_votes,'report_identities',v_spots,'rider_sightings',v_sightings);
end $$;
revoke execute on function public.anonymized_hashes_clear() from public,anon,authenticated;

-- ===== 3. 稽核紀錄 2 年去識別化 =====
alter table public.admin_audit_log add column deidentified_at timestamptz;
comment on column public.admin_audit_log.deidentified_at is
  '滿 2 年去識別化的時間（#267）：對象使用者的 uid 與 before／after 的個資已拿掉，actor 照留。';
create index admin_audit_log_deidentify_idx on public.admin_audit_log(created_at) where deidentified_at is null;

-- before／after 裡會拿掉的鍵（任何層）。目前實際出現的是 user_id
-- （promote_spot 的點位快照）與 reporter_id（resolve_report 的回報快照）；
-- 其餘是防範日後的快照帶進個資。deleted_by、resolved_by 是管理員，照留。
create function private.audit_personal_keys() returns text[]
language sql immutable security definer set search_path='' as $$
  select array['user_id','reporter_id','email','contact_email','account_hint','avatar_url','picture',
    'full_name','display_name','raw_user_meta_data','ip_hash','device_hash']
$$;
-- 名稱換成這段文字（保留「曾有名稱、後來被清除」的變更紀錄）。
create function private.audit_redacted_name() returns text
language sql immutable security definer set search_path='' as $$ select '（已去識別化）' $$;
-- 對象是使用者時的 target_id。
create function private.audit_redacted_target() returns text
language sql immutable security definer set search_path='' as $$ select 'deidentified' $$;

-- 遞迴去識別化一個 jsonb：拿掉個資鍵，非空的 contributor_name 換成固定文字。
create function private.audit_redact(p jsonb) returns jsonb
language plpgsql immutable security definer set search_path='' as $$
begin
  return case jsonb_typeof(p)
    when 'object' then (select coalesce(jsonb_object_agg(e.key,
        case when e.key='contributor_name' and jsonb_typeof(e.value)='string' and e.value<>'""'::jsonb
          then to_jsonb(private.audit_redacted_name())
          else private.audit_redact(e.value) end),'{}'::jsonb)
      from jsonb_each(p) e where e.key<>all(private.audit_personal_keys()))
    when 'array' then (select coalesce(jsonb_agg(private.audit_redact(x.value) order by x.ord),'[]'::jsonb)
      from jsonb_array_elements(p) with ordinality x(value,ord))
    else p end;
end $$;
create function private.audit_redact_target(p_table text,p_id text) returns text
language sql immutable security definer set search_path='' as $$
  select case when p_table='auth.users' then private.audit_redacted_target() else p_id end
$$;
revoke execute on function private.audit_personal_keys(),private.audit_redacted_name(),
  private.audit_redacted_target(),private.audit_redact(jsonb),private.audit_redact_target(text,text)
  from public,anon,authenticated,service_role;

-- 修改的唯一例外：public.admin_audit_deidentify() 在交易內設 app.audit_deidentify，
-- 而且新的一列必須正好是舊列的去識別化結果（滿 2 年、還沒去識別化、其他
-- 欄位不變）。就算別人也設了這個旗標，能做的也只有提早不了的同一個去識別化。
create function public.admin_audit_log_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if coalesce(current_setting('app.audit_deidentify',true),'')='on'
     and old.deidentified_at is null and new.deidentified_at is not null
     and old.created_at<now()-private.retention_audit_log()
     and (to_jsonb(new)-'target_id'-'before'-'after'-'deidentified_at')
       =(to_jsonb(old)-'target_id'-'before'-'after'-'deidentified_at')
     and new.target_id=private.audit_redact_target(old.target_table,old.target_id)
     and new.before is not distinct from private.audit_redact(old.before)
     and new.after is not distinct from private.audit_redact(old.after) then
    return new;
  end if;
  raise exception 'audit log entries cannot be changed' using errcode='42501';
end $$;
revoke execute on function public.admin_audit_log_guard() from public,anon,authenticated;

drop trigger admin_audit_log_immutable on public.admin_audit_log;
create trigger admin_audit_log_immutable before delete on public.admin_audit_log
  for each row execute function public.admin_audit_log_immutable();
create trigger admin_audit_log_guard before update on public.admin_audit_log
  for each row execute function public.admin_audit_log_guard();

-- 去識別化滿 2 年的稽核，一次最多 p_limit 筆；有處理時另寫一筆稽核
-- （系統操作者 …00de，只記筆數與 id 範圍）。回傳處理的筆數。
create function public.admin_audit_deidentify(p_limit int default 5000) returns integer
language plpgsql security definer set search_path='' as $$
declare
  v_cut timestamptz:=now()-private.retention_audit_log();
  v_count integer; v_changed integer; v_first bigint; v_last bigint;
begin
  perform set_config('app.audit_deidentify','on',true);
  with due as (
    select a.id,
      a.target_id is distinct from private.audit_redact_target(a.target_table,a.target_id)
        or a.before is distinct from private.audit_redact(a.before)
        or a.after is distinct from private.audit_redact(a.after) as changed
    from public.admin_audit_log a
    where a.deidentified_at is null and a.created_at<v_cut
    order by a.created_at,a.id
    limit greatest(1,least(coalesce(p_limit,5000),50000))
    for update skip locked
  ), done as (
    update public.admin_audit_log a
      set target_id=private.audit_redact_target(a.target_table,a.target_id),
        before=private.audit_redact(a.before),after=private.audit_redact(a.after),deidentified_at=now()
    from due where a.id=due.id
    returning a.id,due.changed
  )
  select count(*)::int,count(*) filter (where changed)::int,min(id),max(id)
    into v_count,v_changed,v_first,v_last from done;
  perform set_config('app.audit_deidentify','',true);
  if v_count>0 then
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values('00000000-0000-0000-0000-0000000000de','deidentify_audit_log','admin_audit_log',
      v_first::text||'-'||v_last::text,null,
      jsonb_build_object('entries',v_count,'changed',v_changed,'first_id',v_first,'last_id',v_last,
        'created_before',v_cut),
      '稽核紀錄滿 2 年去識別化（#267）');
  end if;
  return v_count;
end $$;
revoke execute on function public.admin_audit_deidentify(int) from public,anon,authenticated;

-- ===== 4. 每日排程 =====
create function public.account_data_retention() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  return jsonb_build_object(
    'usage_events',public.usage_events_prune(),
    'anonymized_hashes',public.anonymized_hashes_clear(),
    'support_requests',public.support_requests_prune(),
    'audit_log',public.admin_audit_deidentify());
end $$;
revoke execute on function public.account_data_retention() from public,anon,authenticated;

-- 客服申請的清除改由這個排程呼叫（202611012000 註明之後併入 #267）。
select cron.unschedule('support-requests-prune')
  where exists(select 1 from cron.job where jobname='support-requests-prune' and username=current_user);
-- 20:29 UTC＝台灣 04:29，在 account-deletion（03:41）之後，避開其他排程的分鐘。
select cron.schedule('account-data-retention','29 20 * * *','select public.account_data_retention()');
