-- 客服表單刪除帳號的身分確認（#285；使用者決定 PM_ANS_20261101_126、_127、
-- _132、_133）。202611012000_support_requests.sql 只收申請者自填的 email，
-- 由管理員代建刪除申請，有冒名刪除的風險。改成由登入信箱的主人自己完成：
--
-- 1. 表單分兩個 email：帳號的登入 email（login_email，只用來比對）與聯絡用
--    email（contact_email，只收一封固定回條，內容和比對結果無關）。
-- 2. 只認帳號的登入 email：auth.users.email 或 auth.identities.email（含 Apple
--    隱藏的電子郵件），不分大小寫；正好對到一個帳號才算對到。
-- 3. 對到可以刪除的帳號時，Edge Function 寄確認信到該登入 email，連結 24 小時
--    有效、只能用一次。資料庫只存 token 的 SHA-256；以申請編號找列、常數時間
--    比對雜湊。打開連結不改變狀態（信件掃描器會自動開連結）：網頁先以 view
--    顯示申請內容；按「是我」（confirm）才由系統直接建立刪除申請（source
--    'support'，與 App 相同的 7 天冷靜期、登出所有裝置、隱藏名稱），再寄通知
--    到同一個登入 email；按「不是我申請的」（deny）作廢申請。之後 token 失效。
-- 4. 例外由系統判斷，不建立刪除申請、表單回應也一樣，只記錄給管理員看
--    （status 'exception'、exception 欄）：沒對到帳號、對到管理員帳號、帳號
--    已在冷靜期、正在刪除或已刪除。帳號已在冷靜期時寄一封狀態信到登入 email
--    （收信者就是信箱主人），告訴他預計刪除時間與取消方式；其餘不寄。
-- 5. 同一個帳號重送：之前還沒確認的申請作廢（舊連結失效）。重送算進「每個
--    登入 email 每台灣日 3 筆」。
-- 6. 管理員不再代為申請：拿掉 admin_v1.request_account_deletion_for；管理站
--    只看紀錄與例外（admin_v1.support_requests）。
-- 7. Apple 帳號照常建立申請。Apple token 撤銷要本人重新以 Apple 登入
--    （apple-revoke，#268／#273 不存 refresh token），這裡無法撤銷，略過；
--    通知信附自行移除「使用 Apple 登入」的步驟。
-- 8. 系統判定的終止狀態都記上結束時間（resolved_at），連結過期由每日清除
--    轉成 expired；管理員手動結案只用於一般客服問題與還在等確認的申請
--    （PM_ANS_20261101_135）。所有最終狀態都從 resolved_at 起算 180 天後清除。
-- 9. 通知信附「取消刪除」連結（PM_ANS_20261101_138）：冷靜期內有效、只能用
--    一次、只存雜湊；打開只顯示，按下取消才走 cancel_account_deletion 同一套
--    流程（private.account_deletion_cancel），稽核來源記 support_link。
-- 10. 重送作廢舊申請時記下 superseded_by（取代它的申請）與結束時間。
-- 11. 聯絡 email 上限：每台灣日 3 筆、30 天內 10 筆，免得用回條騷擾別人。
--
-- 這支之前送出、還在處理中的申請沒有登入 email，不能經連結確認；請結案並
-- 請申請者重新送出。

alter table private.support_requests drop constraint support_requests_status_check,
  add constraint support_requests_status_check check (status in ('open','done','rejected','voided','expired','exception')),
  add column login_email text check (login_email is null or (char_length(login_email) between 3 and 254
    and login_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and login_email=lower(login_email))),
  -- 對到的帳號；帳號刪除後為 null，account_matched 仍保留「當時對到」。
  add column matched_user uuid references auth.users(id) on delete set null,
  add column account_matched boolean not null default false,
  add column confirm_token_hash bytea check (confirm_token_hash is null or octet_length(confirm_token_hash)=32),
  add column confirm_expires_at timestamptz,
  add column confirmed_at timestamptz,
  -- 系統判斷的例外（status 'exception'）。
  add column exception text check (exception in
    ('no_account','admin_account','deletion_pending','deletion_in_progress','account_deleted')),
  -- 建立刪除申請後寄到登入 email 的通知信寄出時間。
  add column deletion_notified_at timestamptz,
  -- 通知信裡「取消刪除」連結 token 的 SHA-256；冷靜期結束即失效。
  add column cancel_token_hash bytea check (cancel_token_hash is null or octet_length(cancel_token_hash)=32),
  add column cancel_expires_at timestamptz,
  add column cancelled_at timestamptz,
  -- 重送時取代這筆的申請（事件紀錄）。
  add column superseded_by uuid,
  add check (account_matched or (matched_user is null and confirm_token_hash is null and confirmed_at is null)),
  add check ((confirm_token_hash is null)=(confirm_expires_at is null)),
  add check ((status='exception')=(exception is not null)),
  add check ((cancel_token_hash is null)=(cancel_expires_at is null));
-- 由通知信的取消連結取消：稽核來源 support_link。
alter table private.account_deletion_audit drop constraint account_deletion_audit_source_check,
  add constraint account_deletion_audit_source_check check (source in ('app','web','support','support_link'));

-- 常數時間比對兩個 32 位元組的雜湊：不論在哪一個位元組不同，都比完。
-- a 為 null（沒有 token）時與全 0 比，照樣比完再回 false。
create function private.support_hash_equal(a bytea,b bytea) returns boolean
language plpgsql immutable set search_path='' as $$
declare
  v_a bytea:=coalesce(a,'\x0000000000000000000000000000000000000000000000000000000000000000'::bytea);
  v_diff int:=0;
begin
  for i in 0..31 loop
    v_diff:=v_diff|(get_byte(v_a,i)#get_byte(b,i));
  end loop;
  return a is not null and v_diff=0;
end $$;
revoke execute on function private.support_hash_equal(bytea,bytea) from public,anon,authenticated,service_role;

create index support_requests_matched_user_idx on private.support_requests(matched_user);
create index support_requests_login_email_idx on private.support_requests(login_email,created_at);
comment on column private.support_requests.contact_email is
  '聯絡用 email：只寄固定回條（#285），不寄任何和帳號有關的信。';
comment on column private.support_requests.login_email is
  '申請者填的帳號登入 email（#285），只用來比對帳號；確認信、狀態信與通知信只寄到這裡。';
comment on column private.support_requests.confirm_token_hash is
  '確認連結 token 的 SHA-256（#285）；原文只在確認信裡。確認、作廢或過期即失效。';

-- 登入 email 對到的帳號：正好一個才回傳，否則 null。
create function private.support_login_account(p_email text) returns uuid
language sql stable security definer set search_path='' as $$
  select case when count(*)=1 then (array_agg(m.id))[1] end
  from (select distinct u.id from auth.users u
    where u.deleted_at is null and not u.is_anonymous
      and (lower(u.email)=p_email
        or exists(select 1 from auth.identities i where i.user_id=u.id and lower(i.email)=p_email))) m;
$$;
revoke execute on function private.support_login_account(text) from public,anon,authenticated,service_role;

-- 不能由連結建立刪除申請的原因；可以時為 null。執行器領取後 1 小時內算刪除中。
create function private.support_exception_for(p_user uuid) returns text
language sql stable security definer set search_path='' as $$
  select case
    when p_user is null or not exists(select 1 from auth.users u where u.id=p_user and u.deleted_at is null) then 'account_deleted'
    when exists(select 1 from private.account_deletion_requests r
      where r.user_id=p_user and r.claimed_at>now()-interval '1 hour') then 'deletion_in_progress'
    when exists(select 1 from private.account_deletion_requests r where r.user_id=p_user) then 'deletion_pending'
    when private.account_is_admin(p_user) then 'admin_account'
    end;
$$;
revoke execute on function private.support_exception_for(uuid) from public,anon,authenticated,service_role;

-- ===== 送出（Edge Function 用）=====
-- p_token_hash：Edge Function 每次都產生 token（對不到也一樣，時間上看不出
-- 差別），傳入 SHA-256 的十六進位；只有要寄確認信時才存。回傳要寄給登入
-- email 的信（mail：confirm、status 或 null）供 Edge Function 決定，不回給申請者。
drop function public.support_request_submit(text,text,text,text,text);
create function public.support_request_submit(p_kind text,p_contact_email text,p_login_email text,
  p_hint text,p_message text,p_ip_hash text,p_token_hash text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_contact text:=lower(btrim(coalesce(p_contact_email,'')));
  v_login text:=lower(btrim(coalesce(p_login_email,'')));
  v_day timestamptz:=public.report_day_start();
  v_user uuid;
  v_exception text;
  v_id uuid;
begin
  if p_ip_hash is null or char_length(p_ip_hash)<>64
     or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' or v_login='' then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  -- 同一網路或 email 同時送出時依序計數（鎖的順序固定，不會互相等待）。
  perform pg_advisory_xact_lock(hashtextextended('support-ip:'||p_ip_hash,0));
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||least(v_contact,v_login),0));
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||greatest(v_contact,v_login),0));
  -- 每網路 5 筆；每個登入 email 3 筆（重送也算，免得用來灌爆對方信箱）；
  -- 每個聯絡 email 3 筆、30 天內 10 筆（回條）。
  if (select count(*) from private.support_requests s where s.ip_hash=p_ip_hash and s.created_at>=v_day)>=5
     or (select count(*) from private.support_requests s where s.login_email=v_login and s.created_at>=v_day)>=3
     or (select count(*) from private.support_requests s where s.contact_email=v_contact and s.created_at>=v_day)>=3
     or (select count(*) from private.support_requests s
       where s.contact_email=v_contact and s.created_at>=now()-interval '30 days')>=10 then
    raise exception 'support.rate_limited' using errcode='P0001';
  end if;
  v_user:=private.support_login_account(v_login);
  v_exception:=case when v_user is null then 'no_account' else private.support_exception_for(v_user) end;
  v_id:=gen_random_uuid();
  if v_exception is null then
    -- 重送：同一帳號還沒確認的申請作廢，舊連結失效；記下取代它的申請。
    update private.support_requests s
      set status='voided',resolved_at=now(),resolution_note='已重送，舊連結作廢',superseded_by=v_id,
        confirm_token_hash=null,confirm_expires_at=null
      where s.matched_user=v_user and s.status='open';
  end if;
  insert into private.support_requests(id,kind,contact_email,login_email,account_hint,message,ip_hash,
      matched_user,account_matched,confirm_token_hash,confirm_expires_at,status,exception,resolved_at)
    values(v_id,p_kind,v_contact,v_login,btrim(coalesce(p_hint,'')),btrim(coalesce(p_message,'')),p_ip_hash,
      v_user,v_user is not null,
      case when v_exception is null then decode(p_token_hash,'hex') end,
      case when v_exception is null then now()+interval '24 hours' end,
      case when v_exception is null then 'open' else 'exception' end,
      v_exception,
      case when v_exception is not null then now() end);
  return jsonb_build_object('id',v_id,
    'mail',case when v_exception is null then 'confirm' when v_exception='deletion_pending' then 'status' end,
    'scheduled_at',case when v_exception='deletion_pending' then
      (select r.scheduled_at from private.account_deletion_requests r where r.user_id=v_user) end);
exception when check_violation or not_null_violation then
  raise exception 'request.invalid' using errcode='22023';
end $$;
revoke execute on function public.support_request_submit(text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.support_request_submit(text,text,text,text,text,text,text) to service_role;

-- 有待寄的通知時叫 Edge Function support-mail；vault 沒有 project_url 或
-- support_mail_secret 時不做事（由下次排程再試）。pg_net 在交易提交後才送出。
create function public.support_mail_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text;
begin
  if not exists(select 1 from private.support_requests s
      join private.account_deletion_requests r on r.request_id=s.deletion_request_id
      where s.deletion_notified_at is null and s.login_email is not null) then
    return null;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='support_mail_secret';
  if v_url is null or v_secret is null or v_url !~ '^https://' then return null; end if;
  return net.http_post(
    url:=rtrim(v_url,'/')||'/functions/v1/support-mail',
    headers:=jsonb_build_object('Content-Type','application/json','x-support-mail-secret',v_secret),
    body:='{}'::jsonb,
    timeout_milliseconds:=60000);
end $$;
revoke all on function public.support_mail_tick() from public,anon,authenticated;

select cron.schedule('support-mail','7-59/15 * * * *','select public.support_mail_tick()');

-- ===== 確認連結（Edge Function support-confirm 用）=====
-- p_action：view（只讀）、confirm（是我）、deny（不是我申請的）。
-- token 不對（找不到、雜湊不符、已用過、已作廢、已過期）一律 {"result":"invalid"}，
-- 不分原因。token 對時回 result 與送出時間、聯絡 email（Edge Function 遮罩後
-- 才給網頁）：
--   pending                   待確認（view）
--   deletion_requested        confirm 已建立刪除申請，附 scheduled_at
--   denied                    deny 已作廢
--   resolved                  已結案
--   account_deletion_pending  帳號已在冷靜期中，附 scheduled_at
--   account_deleting          帳號正在刪除或已刪除
--   unavailable               管理員帳號，不能從這裡刪除
-- confirm 遇到例外時記成 exception，不建立申請。
create function public.support_request_link(p_id uuid,p_token_hash text,p_action text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  r private.support_requests;
  v_found boolean;
  v_equal boolean;
  v_exception text;
  v_request uuid;
  v_result text;
begin
  if p_action is null or p_action not in ('view','confirm','deny') then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  if p_id is null or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('result','invalid');
  end if;
  select * into r from private.support_requests s where s.id=p_id for update;
  v_found:=found;
  v_equal:=private.support_hash_equal(r.confirm_token_hash,decode(p_token_hash,'hex'));
  if not v_found or not v_equal or r.confirm_expires_at<=now() then
    return jsonb_build_object('result','invalid');
  end if;
  if r.status<>'open' then
    v_result:='resolved';
  elsif p_action='deny' then
    update private.support_requests s
      set status='voided',resolved_at=now(),resolution_note='申請者表示不是本人申請',
        confirm_token_hash=null,confirm_expires_at=null
      where s.id=p_id;
    v_result:='denied';
  else
    if p_action='confirm' and r.matched_user is not null then
      perform pg_advisory_xact_lock(hashtextextended('account-deletion:'||r.matched_user::text,0));
    end if;
    v_exception:=private.support_exception_for(r.matched_user);
    v_result:=case v_exception
      when 'admin_account' then 'unavailable'
      when 'deletion_pending' then 'account_deletion_pending'
      when 'deletion_in_progress' then 'account_deleting'
      when 'account_deleted' then 'account_deleting'
      else case when p_action='confirm' then 'deletion_requested' else 'pending' end end;
    if p_action='confirm' and v_exception is not null then
      update private.support_requests s
        set status='exception',exception=v_exception,resolved_at=now(),confirmed_at=now(),
          confirm_token_hash=null,confirm_expires_at=null
        where s.id=p_id;
    elsif p_action='confirm' then
      -- 與 App 自助申請相同：7 天冷靜期、隱藏名稱、登出所有裝置。
      insert into private.account_deletion_requests(user_id,source,scheduled_at)
        values(r.matched_user,'support',now()+private.account_deletion_cooling_off())
        returning request_id into v_request;
      insert into private.account_deletion_audit(request_id,event,source) values(v_request,'requested','support');
      update public.community_spots c set contributor_name='' where c.user_id=r.matched_user;
      delete from auth.sessions a where a.user_id=r.matched_user;
      update private.support_requests s
        set status='done',resolved_at=now(),confirmed_at=now(),deletion_request_id=v_request,
          resolution_note='已由登入信箱確認並建立刪除申請',confirm_token_hash=null,confirm_expires_at=null
        where s.id=p_id;
      -- 通知信：交易提交後由 pg_net 送出；排不進去或沒送成都由排程補寄。
      begin
        perform public.support_mail_tick();
      exception when others then
        null;
      end;
    end if;
  end if;
  return jsonb_build_object('result',v_result,'submitted_at',r.created_at,'contact_email',r.contact_email,
    'scheduled_at',case when v_result in ('deletion_requested','account_deletion_pending') then
      (select d.scheduled_at from private.account_deletion_requests d where d.user_id=r.matched_user) end);
end $$;
revoke execute on function public.support_request_link(uuid,text,text) from public,anon,authenticated;
grant execute on function public.support_request_link(uuid,text,text) to service_role;

-- ===== 建立刪除申請後的通知信（Edge Function support-mail 用）=====
-- 待寄：刪除申請還在（沒被取消或已執行）、還沒寄。寄到登入 email。
create function public.support_deletion_notices(p_limit int)
returns table(id uuid,email text,scheduled_at timestamptz,apple boolean)
language sql stable security definer set search_path='' as $$
  select s.id,s.login_email,r.scheduled_at,
    exists(select 1 from auth.identities i where i.user_id=r.user_id and i.provider='apple')
  from private.support_requests s
  join private.account_deletion_requests r on r.request_id=s.deletion_request_id
  where s.deletion_notified_at is null and s.login_email is not null
  order by s.created_at
  limit greatest(1,least(coalesce(p_limit,50),200));
$$;
revoke execute on function public.support_deletion_notices(int) from public,anon,authenticated;
grant execute on function public.support_deletion_notices(int) to service_role;

create function public.support_deletion_notified(p_id uuid) returns void
language sql volatile security definer set search_path='' as $$
  update private.support_requests set deletion_notified_at=now() where id=p_id and deletion_notified_at is null;
$$;
revoke execute on function public.support_deletion_notified(uuid) from public,anon,authenticated;
grant execute on function public.support_deletion_notified(uuid) to service_role;

-- 通知信寄出前存「取消刪除」連結的雜湊（Edge Function 產生 token），到預計
-- 刪除時間為止有效。重寄時換新的 token（舊信沒寄成）。刪除申請已不在或已寄過
-- 時回 false，不存。
create function public.support_cancel_token(p_id uuid,p_token_hash text) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare v_scheduled timestamptz;
begin
  if p_id is null or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  select r.scheduled_at into v_scheduled
    from private.support_requests s
    join private.account_deletion_requests r on r.request_id=s.deletion_request_id
    where s.id=p_id and s.deletion_notified_at is null;
  if v_scheduled is null then return false; end if;
  update private.support_requests s
    set cancel_token_hash=decode(p_token_hash,'hex'),cancel_expires_at=v_scheduled
    where s.id=p_id;
  return true;
end $$;
revoke execute on function public.support_cancel_token(uuid,text) from public,anon,authenticated;
grant execute on function public.support_cancel_token(uuid,text) to service_role;

-- ===== 取消刪除連結（Edge Function support-confirm 用）=====
-- p_action：view（只讀）、cancel（取消刪除）。token 不對（找不到、雜湊不符、
-- 已用過、已過冷靜期）一律 {"result":"invalid"}。token 對時回：
--   pending           冷靜期中（view），附 scheduled_at
--   cancelled         已取消（cancel）
--   not_pending       刪除申請已不在（例如已在 App 取消），token 失效
--   account_deleting  正在刪除或已刪除
-- 取消與 api_v1.cancel_account_deletion 同一套流程，稽核來源 support_link。
create function public.support_cancel_link(p_id uuid,p_token_hash text,p_action text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  r private.support_requests;
  v private.account_deletion_requests;
  v_found boolean;
  v_equal boolean;
  v_result text;
begin
  if p_action is null or p_action not in ('view','cancel') then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  if p_id is null or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('result','invalid');
  end if;
  select * into r from private.support_requests s where s.id=p_id for update;
  v_found:=found;
  v_equal:=private.support_hash_equal(r.cancel_token_hash,decode(p_token_hash,'hex'));
  if not v_found or not v_equal or r.cancel_expires_at<=now() then
    return jsonb_build_object('result','invalid');
  end if;
  if r.matched_user is null then
    return jsonb_build_object('result','account_deleting');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:'||r.matched_user::text,0));
  select * into v from private.account_deletion_requests d
    where d.user_id=r.matched_user and d.request_id=r.deletion_request_id for update;
  if not found then
    update private.support_requests s set cancel_token_hash=null,cancel_expires_at=null where s.id=p_id;
    return jsonb_build_object('result','not_pending');
  end if;
  if v.claimed_at>now()-interval '1 hour' then
    v_result:='account_deleting';
  elsif p_action='view' then
    v_result:='pending';
  else
    v.source:='support_link';
    perform private.account_deletion_cancel(v);
    update private.support_requests s
      set cancelled_at=now(),cancel_token_hash=null,cancel_expires_at=null
      where s.id=p_id;
    v_result:='cancelled';
  end if;
  return jsonb_build_object('result',v_result,
    'scheduled_at',case when v_result='pending' then v.scheduled_at end);
end $$;
revoke execute on function public.support_cancel_link(uuid,text,text) from public,anon,authenticated;
grant execute on function public.support_cancel_link(uuid,text,text) to service_role;

-- ===== 保留期 =====
-- 系統判定的終止狀態都記上 resolved_at（PM_ANS_20261101_135）：已建立刪除
-- 申請（done）、作廢（voided）、例外（exception）在當下記；連結過期由每日
-- 清除（account-data-retention 呼叫）先轉成 expired，resolved_at 記過期時間。
-- 之後一律結案 180 天後刪除。
create or replace function public.support_requests_prune() returns integer
language plpgsql volatile security definer set search_path='' as $$
declare v_count integer;
begin
  update private.support_requests s
    set status='expired',resolved_at=s.confirm_expires_at,confirm_token_hash=null,confirm_expires_at=null
    where s.status='open' and s.confirm_expires_at<=now();
  -- 過了冷靜期的取消連結雜湊也清掉（本來就失效）。
  update private.support_requests s set cancel_token_hash=null,cancel_expires_at=null
    where s.cancel_expires_at<=now();
  delete from private.support_requests s where s.resolved_at<now()-interval '180 days';
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke execute on function public.support_requests_prune() from public,anon,authenticated;

-- ===== 管理站（admin_v1）=====
-- 管理員不再代為申請刪除（PM_ANS_20261101_133）。
drop function admin_v1.request_account_deletion_for(uuid,uuid,text);

-- 唯讀紀錄：多了 login_email、account_matched、matched_user、email_confirmed_at、
-- exception、deletion_notified_at、cancelled_at、superseded_by 與
-- voided／expired／exception 狀態；其餘與
-- 202611012000_support_requests.sql 相同。
create or replace function admin_v1.support_requests(p_status text default 'open',p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_admin();
  if p_status is null or p_status not in ('open','done','rejected','voided','expired','exception','all') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_status"}';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_limit"}';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',s.id,'kind',s.kind,'contact_email',s.contact_email,'login_email',s.login_email,
      'account_hint',s.account_hint,
      'message',s.message,'status',s.status,'created_at',s.created_at,'notified_at',s.notified_at,
      'resolved_at',s.resolved_at,'resolution_note',s.resolution_note,
      'deletion_requested',s.deletion_request_id is not null,
      'account_matched',s.account_matched,'matched_user',s.matched_user,
      'email_confirmed_at',s.confirmed_at,'exception',s.exception,
      'deletion_notified_at',s.deletion_notified_at,'cancelled_at',s.cancelled_at,
      'superseded_by',s.superseded_by) order by s.created_at desc)
    from (select * from private.support_requests s
      where p_status='all' or s.status=p_status order by s.created_at desc limit p_limit) s),'[]'::jsonb);
end $$;
revoke execute on function admin_v1.support_requests(text,int) from public;
grant execute on function admin_v1.support_requests(text,int) to authenticated;
