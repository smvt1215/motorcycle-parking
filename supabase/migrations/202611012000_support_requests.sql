-- 客服表單（#269；使用者決定 PM_ANS_20261101_115、_116）：無法登入的人
-- （被停權、帳號遺失）從 App 外的刪除網頁申請刪除帳號。
--
-- 1. private.support_requests：只經 Edge Function support-request（service
--    role）寫入，管理員經 admin_v1 讀取與結案。客戶端角色沒有任何權限。
-- 2. 頻率限制：每網路（REPORT_HASH_SECRET 的 HMAC）每台灣日 5 筆、每個
--    email 每台灣日 3 筆。防機器人由 Edge Function 驗 App Check
--    （reCAPTCHA Enterprise 網頁 provider）。
-- 3. 通知管理員：Edge Function 寄信，信中只有申請編號與管理站連結；寄出
--    後記 notified_at。
-- 4. 管理員確認身分後代為建立刪除申請（source 'support'），同樣 7 天冷靜期。
-- 5. 結案 180 天後刪除（pg_cron 每日；之後併入 #267 的清除排程）。

create table private.support_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('account_deletion')),
  contact_email text not null check (char_length(contact_email) between 3 and 254
    and contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and contact_email=lower(contact_email)),
  -- 申請者說明的帳號線索（登入方式、當時的 email 或顯示名稱）。
  account_hint text not null default '' check (char_length(account_hint)<=200),
  message text not null default '' check (char_length(message)<=1000),
  ip_hash text not null check (char_length(ip_hash)=64),
  status text not null default 'open' check (status in ('open','done','rejected')),
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text not null default '' check (char_length(resolution_note)<=500),
  -- 管理員代建的刪除申請（private.account_deletion_requests.request_id）。
  deletion_request_id uuid,
  check ((status='open')=(resolved_at is null))
);
create index support_requests_open_idx on private.support_requests(status,created_at desc);
create index support_requests_ip_idx on private.support_requests(ip_hash,created_at);
create index support_requests_email_idx on private.support_requests(contact_email,created_at);
alter table private.support_requests enable row level security;
revoke all on private.support_requests from public,anon,authenticated,service_role;
comment on table private.support_requests is
  '客服表單（#269）：無法登入者的刪除帳號申請；結案 180 天後刪除。';

-- 管理員代建的刪除申請：來源 support。
alter table private.account_deletion_requests drop constraint account_deletion_requests_source_check,
  add constraint account_deletion_requests_source_check check (source in ('app','web','support'));
alter table private.account_deletion_audit drop constraint account_deletion_audit_source_check,
  add constraint account_deletion_audit_source_check check (source in ('app','web','support'));

-- ===== 送出（Edge Function 用）=====
create function public.support_request_submit(p_kind text,p_email text,p_hint text,p_message text,p_ip_hash text)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare
  v_email text:=lower(btrim(coalesce(p_email,'')));
  v_day timestamptz:=public.report_day_start();
  v_id uuid;
begin
  if p_ip_hash is null or char_length(p_ip_hash)<>64 then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  -- 同一網路或 email 同時送出時依序計數。
  perform pg_advisory_xact_lock(hashtextextended('support-ip:'||p_ip_hash,0));
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||v_email,0));
  if (select count(*) from private.support_requests s where s.ip_hash=p_ip_hash and s.created_at>=v_day)>=5
     or (select count(*) from private.support_requests s where s.contact_email=v_email and s.created_at>=v_day)>=3 then
    raise exception 'support.rate_limited' using errcode='P0001';
  end if;
  insert into private.support_requests(kind,contact_email,account_hint,message,ip_hash)
    values(p_kind,v_email,btrim(coalesce(p_hint,'')),btrim(coalesce(p_message,'')),p_ip_hash)
    returning id into v_id;
  return v_id;
exception when check_violation or not_null_violation then
  raise exception 'request.invalid' using errcode='22023';
end $$;
revoke execute on function public.support_request_submit(text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.support_request_submit(text,text,text,text,text) to service_role;

create function public.support_request_notified(p_id uuid) returns void
language sql volatile security definer set search_path='' as $$
  update private.support_requests set notified_at=now() where id=p_id and notified_at is null;
$$;
revoke execute on function public.support_request_notified(uuid) from public,anon,authenticated;
grant execute on function public.support_request_notified(uuid) to service_role;

-- ===== 管理站（admin_v1）=====
-- 列出申請：預設待處理，新的在前；'all' 列全部（不用 null，產生的用戶端分不出
-- 「沒給」與「給 null」，Codex review，PR #277）。
create function admin_v1.support_requests(p_status text default 'open',p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_admin();
  if p_status is null or p_status not in ('open','done','rejected','all') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_status"}';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_limit"}';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'kind',s.kind,'contact_email',s.contact_email,'account_hint',s.account_hint,
      'message',s.message,'status',s.status,'created_at',s.created_at,'notified_at',s.notified_at,
      'resolved_at',s.resolved_at,'resolution_note',s.resolution_note,
      'deletion_requested',s.deletion_request_id is not null) order by s.created_at desc)
    from (select * from private.support_requests s
      where p_status='all' or s.status=p_status order by s.created_at desc limit p_limit) s),'[]'::jsonb);
end $$;
revoke execute on function admin_v1.support_requests(text,int) from public;
grant execute on function admin_v1.support_requests(text,int) to authenticated;

-- 結案：done（已處理）或 rejected（無法確認身分等）。稽核不記 email 或內容。
create function admin_v1.resolve_support_request(p_id uuid,p_status text,p_note text default '')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_note text:=btrim(coalesce(p_note,''));
  v_before text;
begin
  perform private.require_admin();
  if p_id is null or p_status is null or p_status not in ('done','rejected') or char_length(v_note)>500 then
    raise sqlstate 'PT400' using message='request.invalid';
  end if;
  select s.status into v_before from private.support_requests s where s.id=p_id for update;
  if not found then
    raise sqlstate 'PT404' using message='support.not_found';
  end if;
  if v_before<>'open' then
    raise sqlstate 'PT409' using message='support.already_resolved';
  end if;
  update private.support_requests s
    set status=p_status,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note
    where s.id=p_id;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'resolve_support_request','support_requests',p_id::text,
      jsonb_build_object('status',v_before),jsonb_build_object('status',p_status),v_note);
  return jsonb_build_object('id',p_id,'status',p_status);
end $$;
revoke execute on function admin_v1.resolve_support_request(uuid,text,text) from public;
grant execute on function admin_v1.resolve_support_request(uuid,text,text) to authenticated;

-- 管理員確認身分後代為申請刪除：與自助申請相同的 7 天冷靜期、立即隱藏
-- 名稱；管理員帳號不行（要先移除權限）。冷靜期內本人登入後可在 App 選擇取消。
create function admin_v1.request_account_deletion_for(p_user uuid,p_support_request uuid,p_note text default '')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_note text:=btrim(coalesce(p_note,''));
  v_request uuid;
  v_status text;
begin
  perform private.require_admin();
  if p_user is null or p_support_request is null or char_length(v_note)>500 then
    raise sqlstate 'PT400' using message='request.invalid';
  end if;
  select s.status into v_status from private.support_requests s where s.id=p_support_request for update;
  if not found then
    raise sqlstate 'PT404' using message='support.not_found';
  end if;
  if v_status<>'open' then
    raise sqlstate 'PT409' using message='support.already_resolved';
  end if;
  if not exists(select 1 from auth.users u where u.id=p_user and u.deleted_at is null) then
    raise sqlstate 'PT404' using message='account.not_found';
  end if;
  if private.account_is_admin(p_user) then
    raise sqlstate 'PT403' using message='account.admin_cannot_self_delete';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:'||p_user::text,0));
  select r.request_id into v_request from private.account_deletion_requests r where r.user_id=p_user;
  if not found then
    insert into private.account_deletion_requests(user_id,source,scheduled_at)
      values(p_user,'support',now()+private.account_deletion_cooling_off())
      returning request_id into v_request;
    insert into private.account_deletion_audit(request_id,event,source) values(v_request,'requested','support');
    update public.community_spots s set contributor_name='' where s.user_id=p_user;
  end if;
  update private.support_requests s set deletion_request_id=v_request where s.id=p_support_request;
  -- 稽核只記帳號 id（與停權稽核相同）與客服申請編號。
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'request_account_deletion','auth.users',p_user::text,null,
      jsonb_build_object('support_request',p_support_request,'deletion_request',v_request),v_note);
  return private.account_deletion_state(p_user)||jsonb_build_object('support_request',p_support_request);
end $$;
revoke execute on function admin_v1.request_account_deletion_for(uuid,uuid,text) from public;
grant execute on function admin_v1.request_account_deletion_for(uuid,uuid,text) to authenticated;

-- ===== 保留期 =====
create function public.support_requests_prune() returns integer
language sql volatile security definer set search_path='' as $$
  with gone as (delete from private.support_requests s
    where s.resolved_at<now()-interval '180 days' returning 1)
  select count(*)::int from gone;
$$;
revoke execute on function public.support_requests_prune() from public,anon,authenticated;

select cron.schedule('support-requests-prune','53 19 * * *','select public.support_requests_prune()');
