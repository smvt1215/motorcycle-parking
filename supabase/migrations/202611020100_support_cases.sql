-- 客服案件系統（#295；使用者決定 PM_ANS_20261101_144、_147，API 形狀與
-- admin station refactor 對齊 T295_API_20261101_01）。刪除帳號的流程
-- （#285，202611012200_support_deletion_verify.sql）不變。
--
-- 1. 案件類型：一般問題（general）、資料錯誤或侵權（data_issue）、檢舉與申訴
--    （complaint）、個資權利請求（privacy：查詢 access、更正 correction、
--    複本 copy）、刪除帳號（account_deletion，既有）。來源：表單（web）、
--    寄到 support@ 的信（email，Edge Function support-inbound，第 2 層）。
-- 2. 往來紀錄（private.support_messages）：客服回覆（out，經 Resend 寄出，
--    寄送結果留存）與使用者的補充（in，案件連結或回信）。客服只能回覆還沒
--    結案、可以回覆的案件：刪除帳號不回覆（聯絡 email 只收固定回條）；個資
--    權利請求要登入信箱的主人先確認（比照 #285），回覆只寄到登入 email。
-- 3. 案件連結與回信地址（private.support_case_tokens）：每封寄出的信一個
--    新的案件連結（30 天有效、每個連結最多送 5 次）與 Reply-To
--    reply+<token>@ 的 token；資料庫只存 SHA-256。每案件的補充每台灣日 10
--    則、總計 50 則；客服回覆每案件每台灣日 10 則、總計 50 則。
-- 4. 已結案（done、rejected）30 天內收到補充或回信時重新開啟同一案件；超過
--    30 天由呼叫端改開新案件（related_to 指向舊案）。
-- 5. 回覆期限 due_at：送出（或重新開啟）後 5 個工作天（台灣時間；
--    public.holidays 有資料時依它，補班日算工作日；沒有資料的日子週一到五
--    算工作日），期限是第 5 個工作天結束。
-- 6. 帳號已在冷靜期時寄的狀態信附一次性「取消刪除」連結（冷靜期內有效、
--    只能用一次、只存雜湊）；原刪除申請來自 App 或客服表單都可以用
--    （status_request_id 記下狀態信所指的刪除申請）。
-- 7. 保存：最終狀態從 resolved_at 起 180 天整筆刪除（往來紀錄與 token 一併
--    刪除，on delete cascade），沿用 support_requests_prune()；重新開啟時
--    resolved_at 清空。過期的案件連結 token 每日清掉。

-- ===== 1. 案件欄位 =====
alter table private.support_requests
  drop constraint support_requests_kind_check,
  add constraint support_requests_kind_check
    check (kind in ('general','data_issue','complaint','privacy','account_deletion')),
  drop constraint support_requests_message_check,
  add constraint support_requests_message_check check (char_length(message)<=4000
    and (kind<>'account_deletion' or char_length(message)<=1000)),
  -- 從 email 進來的案件沒有網路雜湊。
  alter column ip_hash drop not null,
  add column source text not null default 'web' check (source in ('web','email')),
  add column subject text not null default '' check (char_length(subject)<=200),
  add column privacy_right text check (privacy_right in ('access','correction','copy')),
  add column reopened_at timestamptz,
  -- 結案超過 30 天後收到回信開的新案件：指向舊案。
  add column related_to uuid,
  -- email 來源的原始信件：SPF／DKIM 結果（Authentication-Results）與附件檔名。
  add column mail_spf text check (mail_spf in ('pass','fail','softfail','neutral','none','temperror','permerror','policy')),
  add column mail_dkim text check (mail_dkim in ('pass','fail','softfail','neutral','none','temperror','permerror','policy')),
  add column mail_attachments text[] not null default '{}' check (cardinality(mail_attachments)<=20),
  add column suspicious boolean not null default false,
  -- 狀態信（帳號已在冷靜期）的取消連結所指的刪除申請（App 或客服表單建立）。
  add column status_request_id uuid,
  add check ((kind='privacy')=(privacy_right is not null)),
  add check (source='email' or ip_hash is not null),
  add check (source='web' or kind='general'),
  add check (kind in ('privacy','account_deletion') or login_email is null),
  add check (kind<>'privacy' or login_email is not null);
create index support_requests_kind_idx on private.support_requests(kind,status,created_at desc);
comment on column private.support_requests.kind is
  '案件類型（#295）：general 一般問題、data_issue 資料錯誤或侵權、complaint 檢舉與申訴、privacy 個資權利請求、account_deletion 刪除帳號（#285）。';
comment on column private.support_requests.source is '來源（#295）：web 客服表單、email 寄到 support@ 的信。';

-- ===== 2. 往來紀錄 =====
create table private.support_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references private.support_requests(id) on delete cascade,
  -- out：客服回覆；in：使用者的補充。
  direction text not null check (direction in ('in','out')),
  -- admin：管理站回覆；case_link：案件連結的補充；email：回信。
  channel text not null check (channel in ('admin','case_link','email')),
  body text not null check (char_length(body) between 1 and 4000),
  -- 實際時間：同一交易裡的幾則也分得出先後。
  created_at timestamptz not null default clock_timestamp(),
  -- 回覆的管理員。
  author uuid,
  -- 回信的寄件人與 SPF／DKIM 結果；附件只記檔名。
  from_email text check (char_length(from_email)<=254),
  spf text check (spf in ('pass','fail','softfail','neutral','none','temperror','permerror','policy')),
  dkim text check (dkim in ('pass','fail','softfail','neutral','none','temperror','permerror','policy')),
  suspicious boolean not null default false,
  attachments text[] not null default '{}' check (cardinality(attachments)<=20),
  -- 寄送（只有 out）：收件人、狀態、次數、結果。
  to_email text check (char_length(to_email)<=254),
  delivery_status text check (delivery_status in ('queued','sending','sent','failed')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  claimed_at timestamptz,
  sent_at timestamptz,
  send_error text check (char_length(send_error)<=200),
  resend_id text check (char_length(resend_id)<=100),
  check ((direction='out')=(channel='admin')),
  check ((direction='out')=(delivery_status is not null and to_email is not null)),
  check (direction='out' or author is null),
  check ((channel='email')=(from_email is not null))
);
create index support_messages_request_idx on private.support_messages(request_id,created_at);
create index support_messages_delivery_idx on private.support_messages(delivery_status,claimed_at)
  where delivery_status in ('queued','sending','failed');
alter table private.support_messages enable row level security;
revoke all on private.support_messages from public,anon,authenticated,service_role;
comment on table private.support_messages is
  '客服案件的往來紀錄（#295）：客服回覆與寄送結果、使用者的補充。隨案件 180 天後刪除。';

-- ===== 3. 案件連結與回信地址的 token =====
create table private.support_case_tokens (
  -- token 的 SHA-256；原文只在寄出的信裡。
  token_hash bytea primary key check (octet_length(token_hash)=32),
  request_id uuid not null references private.support_requests(id) on delete cascade,
  -- link：案件連結（30 天、最多 5 次）；reply：Reply-To reply+<token>@ 的 token。
  kind text not null check (kind in ('link','reply')),
  -- 帶著它的那封客服回覆；表單回條為 null。
  message_id uuid references private.support_messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  uses integer not null default 0 check (uses between 0 and 5),
  check ((kind='link')=(expires_at is not null))
);
create index support_case_tokens_request_idx on private.support_case_tokens(request_id);
create index support_case_tokens_message_idx on private.support_case_tokens(message_id);
alter table private.support_case_tokens enable row level security;
revoke all on private.support_case_tokens from public,anon,authenticated,service_role;
comment on table private.support_case_tokens is
  '客服案件連結與回信地址 token 的 SHA-256（#295）。案件連結 30 天有效、最多 5 次；隨案件刪除。';

-- ===== 4. 共用判斷 =====
-- 台灣的工作日：public.holidays 有那天時依它（補班日 is_off false），沒有時週一到五。
create function private.support_workday(p_day date) returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((select not h.is_off from public.holidays h where h.date=p_day),
    extract(isodow from p_day)<6);
$$;

-- 回覆期限：p_from 的台灣日期之後第 5 個工作天結束（下一天 00:00 台灣時間）。
create function private.support_due_at(p_from timestamptz) returns timestamptz
language plpgsql stable security definer set search_path='' as $$
declare
  v_day date:=(p_from at time zone 'Asia/Taipei')::date;
  v_left integer:=5;
begin
  while v_left>0 loop
    v_day:=v_day+1;
    if private.support_workday(v_day) then v_left:=v_left-1; end if;
  end loop;
  return (v_day+1)::timestamp at time zone 'Asia/Taipei';
end $$;

-- 客服回覆寄到哪裡；不能回覆時 null。刪除帳號不回覆（聯絡 email 只收固定
-- 回條，#285）；個資權利請求確認本人後只寄到登入 email。
create function private.support_reply_to(r private.support_requests) returns text
language sql stable security definer set search_path='' as $$
  select case
    when r.kind='account_deletion' then null
    when r.kind='privacy' then case when r.confirmed_at is not null and r.matched_user is not null then r.login_email end
    else r.contact_email end;
$$;

-- 結案 30 天內可以由使用者的補充或回信重新開啟。
create function private.support_reopenable(r private.support_requests) returns boolean
language sql stable security definer set search_path='' as $$
  select r.status in ('done','rejected') and r.resolved_at>now()-interval '30 days'
    and private.support_reply_to(r) is not null;
$$;

create function private.support_message_json(m private.support_messages) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',m.id,'direction',m.direction,'channel',m.channel,'body',m.body,
    'created_at',m.created_at,'author',m.author,'from_email',m.from_email,'suspicious',m.suspicious,
    'spf',m.spf,'dkim',m.dkim,'attachments',to_jsonb(m.attachments),
    'to_email',m.to_email,'delivery_status',m.delivery_status,'attempts',m.attempts,
    'sent_at',m.sent_at,'send_error',m.send_error);
$$;

-- 一筆案件給管理站的欄位：202611012200 的欄位加上 #295 的欄位。
create function private.support_request_json(s private.support_requests) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
      'id',s.id,'kind',s.kind,'contact_email',s.contact_email,'login_email',s.login_email,
      'account_hint',s.account_hint,
      'message',s.message,'status',s.status,'created_at',s.created_at,'notified_at',s.notified_at,
      'resolved_at',s.resolved_at,'resolution_note',s.resolution_note,
      'deletion_requested',s.deletion_request_id is not null,
      'account_matched',s.account_matched,'matched_user',s.matched_user,
      'email_confirmed_at',s.confirmed_at,'exception',s.exception,
      'deletion_notified_at',s.deletion_notified_at,'cancelled_at',s.cancelled_at,
      'superseded_by',s.superseded_by,
      'source',s.source,'subject',s.subject,'privacy_right',s.privacy_right,
      'due_at',private.support_due_at(coalesce(s.reopened_at,s.created_at)),
      'reply_to',private.support_reply_to(s),
      'can_reply',s.status='open' and private.support_reply_to(s) is not null,
      'message_count',coalesce(m.n,0),'last_message_at',m.last_at,
      'awaiting_admin',s.status='open' and private.support_reply_to(s) is not null
        and coalesce(m.last_direction,'in')='in',
      'suspicious',s.suspicious or coalesce(m.suspicious,false),
      'reopened_at',s.reopened_at,'related_to',s.related_to)
  from (select count(*)::int as n,max(x.created_at) as last_at,bool_or(x.suspicious) as suspicious,
      (array_agg(x.direction order by x.created_at desc,x.id desc))[1] as last_direction
    from private.support_messages x where x.request_id=s.id) m;
$$;

revoke execute on function private.support_workday(date),private.support_due_at(timestamptz),
  private.support_reply_to(private.support_requests),private.support_reopenable(private.support_requests),
  private.support_message_json(private.support_messages),private.support_request_json(private.support_requests)
  from public,anon,authenticated,service_role;

-- 使用者的一則補充（案件連結或回信）：還沒結案或結案 30 天內才收（後者重新
-- 開啟）；每案件每台灣日 10 則、總計 50 則。回傳 received（附 message_id、
-- reopened）、closed（不能再補充）或 rate_limited。呼叫端先鎖住案件列。
create function private.support_add_inbound(p_request uuid,p_channel text,p_body text,
  p_from text default null,p_spf text default null,p_dkim text default null,
  p_suspicious boolean default false,p_attachments text[] default '{}')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  r private.support_requests;
  v_reopen boolean:=false;
  v_id uuid;
begin
  select * into r from private.support_requests s where s.id=p_request for update;
  if not found then return jsonb_build_object('result','closed'); end if;
  if r.status<>'open' then
    if not private.support_reopenable(r) then return jsonb_build_object('result','closed'); end if;
    v_reopen:=true;
  elsif private.support_reply_to(r) is null then
    return jsonb_build_object('result','closed');
  end if;
  if (select count(*) from private.support_messages m where m.request_id=p_request and m.direction='in'
        and m.created_at>=public.report_day_start())>=10
     or (select count(*) from private.support_messages m where m.request_id=p_request and m.direction='in')>=50 then
    return jsonb_build_object('result','rate_limited');
  end if;
  insert into private.support_messages(request_id,direction,channel,body,from_email,spf,dkim,suspicious,attachments)
    values(p_request,'in',p_channel,p_body,p_from,p_spf,p_dkim,coalesce(p_suspicious,false),coalesce(p_attachments,'{}'))
    returning id into v_id;
  if v_reopen then
    update private.support_requests s
      set status='open',resolved_at=null,resolved_by=null,reopened_at=now()
      where s.id=p_request;
  end if;
  return jsonb_build_object('result','received','message_id',v_id,'reopened',v_reopen);
end $$;
revoke execute on function private.support_add_inbound(uuid,text,text,text,text,text,boolean,text[])
  from public,anon,authenticated,service_role;

-- ===== 5. 送出（Edge Function support-request 用）=====
-- 202611012200 的參數加上 p_subject、p_privacy_right、p_reply_hash。
--   account_deletion：與 202611012200 相同；另外帳號已在冷靜期時，p_token_hash
--     改存成狀態信裡「取消刪除」連結的雜湊（冷靜期內有效）。
--   privacy：比照刪除帳號，登入 email 正好對到一個帳號才寄確認信（p_token_hash，
--     24 小時）；沒對到記成例外 no_account。
--   general／data_issue／complaint：沒有登入 email；p_token_hash 是回條裡案件
--     連結的雜湊（30 天），p_reply_hash 是 Reply-To 的 token 雜湊。
-- 回傳 mail：confirm（確認信到登入 email）、status（狀態信到登入 email）、
-- case（回條附案件連結與 Reply-To）或 null（只寄固定回條）。
drop function public.support_request_submit(text,text,text,text,text,text,text);
create function public.support_request_submit(p_kind text,p_contact_email text,p_login_email text,
  p_hint text,p_message text,p_ip_hash text,p_token_hash text,
  p_subject text default '',p_privacy_right text default null,p_reply_hash text default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_kind text:=coalesce(p_kind,'');
  v_contact text:=lower(btrim(coalesce(p_contact_email,'')));
  v_login text:=lower(btrim(coalesce(p_login_email,'')));
  v_verify boolean:=coalesce(p_kind,'') in ('account_deletion','privacy');
  v_day timestamptz:=public.report_day_start();
  v_user uuid;
  v_exception text;
  v_pending private.account_deletion_requests;
  v_id uuid;
begin
  if v_kind not in ('general','data_issue','complaint','privacy','account_deletion')
     or p_ip_hash is null or char_length(p_ip_hash)<>64
     or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$'
     or (v_verify and v_login='')
     or (not v_verify and (v_login<>'' or p_reply_hash is null or p_reply_hash !~ '^[0-9a-f]{64}$'))
     or ((v_kind='privacy')<>(p_privacy_right is not null)) then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  -- 同一網路或 email 同時送出時依序計數（鎖的順序固定，不會互相等待）。
  perform pg_advisory_xact_lock(hashtextextended('support-ip:'||p_ip_hash,0));
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||least(v_contact,v_login),0));
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||greatest(v_contact,v_login),0));
  -- 每網路 5 筆；每個登入 email 3 筆（重送也算）；每個聯絡 email 3 筆、
  -- 30 天內 10 筆（回條）。各類型合計。
  if (select count(*) from private.support_requests s where s.ip_hash=p_ip_hash and s.created_at>=v_day)>=5
     or (v_verify and (select count(*) from private.support_requests s
       where s.login_email=v_login and s.created_at>=v_day)>=3)
     or (select count(*) from private.support_requests s where s.contact_email=v_contact and s.created_at>=v_day)>=3
     or (select count(*) from private.support_requests s
       where s.contact_email=v_contact and s.created_at>=now()-interval '30 days')>=10 then
    raise exception 'support.rate_limited' using errcode='P0001';
  end if;
  v_id:=gen_random_uuid();
  if not v_verify then
    insert into private.support_requests(id,kind,contact_email,account_hint,message,subject,ip_hash)
      values(v_id,v_kind,v_contact,btrim(coalesce(p_hint,'')),btrim(coalesce(p_message,'')),
        btrim(coalesce(p_subject,'')),p_ip_hash);
    insert into private.support_case_tokens(token_hash,request_id,kind,expires_at)
      values(decode(p_token_hash,'hex'),v_id,'link',now()+interval '30 days'),
            (decode(p_reply_hash,'hex'),v_id,'reply',null);
    return jsonb_build_object('id',v_id,'mail','case','scheduled_at',null);
  end if;
  v_user:=private.support_login_account(v_login);
  v_exception:=case
    when v_user is null then 'no_account'
    when v_kind='account_deletion' then private.support_exception_for(v_user) end;
  if v_exception is null then
    -- 重送：同一帳號、同一類型還沒確認的申請作廢，舊連結失效。
    update private.support_requests s
      set status='voided',resolved_at=now(),resolution_note='已重送，舊連結作廢',superseded_by=v_id,
        confirm_token_hash=null,confirm_expires_at=null
      where s.matched_user=v_user and s.status='open' and s.kind=v_kind and s.confirmed_at is null;
  end if;
  if v_exception='deletion_pending' then
    select * into v_pending from private.account_deletion_requests r where r.user_id=v_user;
  end if;
  insert into private.support_requests(id,kind,contact_email,login_email,account_hint,message,subject,
      privacy_right,ip_hash,matched_user,account_matched,confirm_token_hash,confirm_expires_at,status,
      exception,resolved_at,cancel_token_hash,cancel_expires_at,status_request_id)
    values(v_id,v_kind,v_contact,v_login,btrim(coalesce(p_hint,'')),btrim(coalesce(p_message,'')),
      btrim(coalesce(p_subject,'')),p_privacy_right,p_ip_hash,
      v_user,v_user is not null,
      case when v_exception is null then decode(p_token_hash,'hex') end,
      case when v_exception is null then now()+interval '24 hours' end,
      case when v_exception is null then 'open' else 'exception' end,
      v_exception,
      case when v_exception is not null then now() end,
      -- 狀態信的「取消刪除」連結：冷靜期內有效（App 或客服表單的申請都可）。
      case when v_pending.request_id is not null then decode(p_token_hash,'hex') end,
      v_pending.scheduled_at,
      v_pending.request_id);
  return jsonb_build_object('id',v_id,
    'mail',case when v_exception is null then 'confirm' when v_pending.request_id is not null then 'status' end,
    'scheduled_at',v_pending.scheduled_at);
exception when check_violation or not_null_violation or unique_violation then
  raise exception 'request.invalid' using errcode='22023';
end $$;
revoke execute on function public.support_request_submit(text,text,text,text,text,text,text,text,text,text)
  from public,anon,authenticated;
grant execute on function public.support_request_submit(text,text,text,text,text,text,text,text,text,text)
  to service_role;

-- ===== 6. 本人確認連結：個資權利請求 =====
-- 202611012200 的 support_request_link 加上 privacy：confirm 記下確認時間，
-- 案件仍 open 等客服回覆（result verified）；deny 一樣作廢。回傳多 kind，
-- 讓確認頁換文案；個資權利請求另回請求的項目、主旨與內容，讓信箱主人看清楚
-- 自己確認的是哪一筆（Codex review，PR #301；持有 token 的人就是登入信箱的
-- 主人）。刪除帳號的行為不變。
create or replace function public.support_request_link(p_id uuid,p_token_hash text,p_action text)
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
  elsif r.kind='privacy' then
    -- 帳號在送出後刪除了：記成例外，不再處理。
    if r.matched_user is null or not exists(select 1 from auth.users u where u.id=r.matched_user and u.deleted_at is null) then
      v_result:='account_deleting';
      if p_action='confirm' then
        update private.support_requests s
          set status='exception',exception='account_deleted',resolved_at=now(),
            confirm_token_hash=null,confirm_expires_at=null
          where s.id=p_id;
      end if;
    elsif p_action='confirm' then
      update private.support_requests s
        set confirmed_at=now(),confirm_token_hash=null,confirm_expires_at=null
        where s.id=p_id;
      v_result:='verified';
    else
      v_result:='pending';
    end if;
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
  return jsonb_build_object('result',v_result,'kind',r.kind,'submitted_at',r.created_at,'contact_email',r.contact_email,
    'privacy_right',r.privacy_right,
    'subject',case when r.kind='privacy' then r.subject end,
    'message',case when r.kind='privacy' then r.message end,
    'scheduled_at',case when v_result in ('deletion_requested','account_deletion_pending') then
      (select d.scheduled_at from private.account_deletion_requests d where d.user_id=r.matched_user) end);
end $$;

-- ===== 7. 取消刪除連結：也接狀態信 =====
-- 與 202611012200 相同，只是刪除申請改找 deletion_request_id（確認信建立的）
-- 或 status_request_id（狀態信所指、App 或客服表單建立的）。
create or replace function public.support_cancel_link(p_id uuid,p_token_hash text,p_action text)
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
    where d.user_id=r.matched_user and d.request_id=coalesce(r.deletion_request_id,r.status_request_id) for update;
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

-- ===== 8. 案件連結（Edge Function support-case 用）=====
-- p_action：view（只讀）、reply（送出補充，p_body 1–4000 字）。token 不對
-- （找不到、雜湊不符、過期、不是這個案件的）一律 {"result":"invalid"}。
-- view：result ok、案件編號用的 id、類型、狀態、送出時間、can_reply 與往來
--   紀錄（原始內容是第一則；只有方向、內文、時間）。
-- reply：received（附 message_id、reopened）、closed（已結案超過 30 天或不能
--   補充）、rate_limited（每案件每日 10 則、總計 50 則，或這個連結已用 5 次）。
create function public.support_case_link(p_id uuid,p_token_hash text,p_action text,p_body text default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  r private.support_requests;
  t private.support_case_tokens;
  v_body text:=btrim(coalesce(p_body,''));
  v_out jsonb;
begin
  if p_action is null or p_action not in ('view','reply')
     or (p_action='reply' and char_length(v_body) not between 1 and 4000) then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  if p_id is null or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('result','invalid');
  end if;
  select * into t from private.support_case_tokens k
    where k.token_hash=decode(p_token_hash,'hex') and k.kind='link' for update;
  if not found or t.request_id<>p_id or t.expires_at<=now() then
    return jsonb_build_object('result','invalid');
  end if;
  select * into r from private.support_requests s where s.id=p_id for update;
  if p_action='view' then
    return jsonb_build_object('result','ok','id',r.id,'kind',r.kind,'status',r.status,
      'submitted_at',r.created_at,
      'can_reply',t.uses<5 and private.support_reply_to(r) is not null
        and (r.status='open' or private.support_reopenable(r)),
      'messages',jsonb_build_array(jsonb_build_object('direction','in','body',r.message,'created_at',r.created_at))
        ||coalesce((select jsonb_agg(jsonb_build_object('direction',m.direction,'body',m.body,'created_at',m.created_at)
          order by m.created_at,m.id) from private.support_messages m where m.request_id=r.id),'[]'::jsonb));
  end if;
  if t.uses>=5 then return jsonb_build_object('result','rate_limited'); end if;
  v_out:=private.support_add_inbound(p_id,'case_link',v_body);
  if v_out->>'result'='received' then
    update private.support_case_tokens k set uses=k.uses+1 where k.token_hash=t.token_hash;
  end if;
  return v_out;
end $$;
revoke execute on function public.support_case_link(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.support_case_link(uuid,text,text,text) to service_role;

-- ===== 9. 客服回覆的寄送（Edge Function support-mail 用）=====
-- 領取待寄的回覆：queued，或寄送失敗／中斷（15 分鐘前領取）且還不到 5 次。
-- 原子領取（skip locked），同一則不會被兩個程序同時寄；5 次都失敗留在 failed。
create function public.support_outbound_claim(p_limit int)
returns table(id uuid,request_id uuid,to_email text,body text,kind text,subject text)
language plpgsql volatile security definer set search_path='' as $$
begin
  -- 中斷 5 次的不再重試。
  update private.support_messages m set delivery_status='failed',send_error=coalesce(m.send_error,'interrupted')
    where m.delivery_status='sending' and m.attempts>=5 and m.claimed_at<=now()-interval '15 minutes';
  return query
  with picked as (
    select m.id from private.support_messages m
    where m.direction='out' and (m.delivery_status='queued'
      or (m.delivery_status in ('sending','failed') and m.attempts<5 and m.claimed_at<=now()-interval '15 minutes'))
    order by m.created_at
    limit greatest(1,least(coalesce(p_limit,50),200))
    for update of m skip locked),
  claimed as (
    update private.support_messages m
      set delivery_status='sending',attempts=m.attempts+1,claimed_at=now()
    from picked where m.id=picked.id
    returning m.id,m.request_id,m.to_email,m.body)
  select c.id,c.request_id,c.to_email,c.body,s.kind,s.subject
  from claimed c join private.support_requests s on s.id=c.request_id;
end $$;
revoke execute on function public.support_outbound_claim(int) from public,anon,authenticated;
grant execute on function public.support_outbound_claim(int) to service_role;

-- 寄出前存這封信的案件連結（30 天）與回信 token 的雜湊。只給 15 分鐘內領取
-- 的程序；否則回 false，不存。
create function public.support_outbound_tokens(p_message uuid,p_link_hash text,p_reply_hash text)
returns boolean language plpgsql volatile security definer set search_path='' as $$
declare v_request uuid;
begin
  if p_message is null or p_link_hash is null or p_link_hash !~ '^[0-9a-f]{64}$'
     or p_reply_hash is null or p_reply_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  select m.request_id into v_request from private.support_messages m
    where m.id=p_message and m.delivery_status='sending' and m.claimed_at>now()-interval '15 minutes'
    for update;
  if v_request is null then return false; end if;
  -- 上一次的 token 不刪：寄送結果不確定（逾時、連線中斷）時，信可能已經送達
  -- （Codex review，PR #301）。沒送達的 token 不在任何人手上，留著無害。
  insert into private.support_case_tokens(token_hash,request_id,kind,message_id,expires_at)
    values(decode(p_link_hash,'hex'),v_request,'link',p_message,now()+interval '30 days'),
          (decode(p_reply_hash,'hex'),v_request,'reply',p_message,null);
  return true;
end $$;
revoke execute on function public.support_outbound_tokens(uuid,text,text) from public,anon,authenticated;
grant execute on function public.support_outbound_tokens(uuid,text,text) to service_role;

-- 寄送結果：sent（Resend 的 id）或 failed（錯誤摘要，不含 email 或內容）。
-- 失敗也保留這次的 token：逾時或連線中斷時信可能已經送達（Codex review，
-- PR #301），隨案件一起刪除。
create function public.support_outbound_result(p_message uuid,p_sent boolean,p_resend_id text default null,
  p_error text default null) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
  if p_sent then
    update private.support_messages m
      set delivery_status='sent',sent_at=now(),resend_id=left(p_resend_id,100),send_error=null
      where m.id=p_message and m.delivery_status='sending';
  else
    update private.support_messages m
      set delivery_status='failed',send_error=left(coalesce(nullif(p_error,''),'failed'),200)
      where m.id=p_message and m.delivery_status='sending';
  end if;
end $$;
revoke execute on function public.support_outbound_result(uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.support_outbound_result(uuid,boolean,text,text) to service_role;

-- 有待寄的刪除通知或客服回覆時叫 Edge Function support-mail（其餘與
-- 202611012200 相同）。
create or replace function public.support_mail_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text;
begin
  if not exists(select 1 from private.support_requests s
      join private.account_deletion_requests r on r.request_id=s.deletion_request_id
      where s.deletion_notified_at is null and s.login_email is not null)
     and not exists(select 1 from private.support_messages m
      where m.delivery_status='queued'
        or (m.delivery_status in ('sending','failed') and m.attempts<5 and m.claimed_at<=now()-interval '15 minutes')) then
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

-- ===== 10. 保存期 =====
-- 與 202611012200 相同，另外刪掉過期的案件連結 token。
create or replace function public.support_requests_prune() returns integer
language plpgsql volatile security definer set search_path='' as $$
declare v_count integer;
begin
  update private.support_requests s
    set status='expired',resolved_at=s.confirm_expires_at,confirm_token_hash=null,confirm_expires_at=null
    where s.status='open' and s.confirm_expires_at<=now();
  update private.support_requests s set cancel_token_hash=null,cancel_expires_at=null
    where s.cancel_expires_at<=now();
  delete from private.support_case_tokens k where k.kind='link' and k.expires_at<=now();
  delete from private.support_requests s where s.resolved_at<now()-interval '180 days';
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke execute on function public.support_requests_prune() from public,anon,authenticated;

-- ===== 11. 管理站（admin_v1）=====
-- 列表：多 p_kind（五種或 all）與 p_awaiting_admin（null 不篩；true＝待客服
-- 回覆），每列多 #295 的欄位。
drop function admin_v1.support_requests(text,int);
create function admin_v1.support_requests(p_status text default 'open',p_kind text default 'all',
  p_awaiting_admin boolean default null,p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_admin();
  if p_status is null or p_status not in ('open','done','rejected','voided','expired','exception','all') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_status"}';
  end if;
  if p_kind is null or p_kind not in ('general','data_issue','complaint','privacy','account_deletion','all') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_kind"}';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_limit"}';
  end if;
  -- 先篩再取前 p_limit 筆。
  return coalesce((select jsonb_agg(y.j order by y.created_at desc,y.id)
    from (select x.id,x.created_at,x.j
      from (select s.id,s.created_at,private.support_request_json(s) as j
        from private.support_requests s
        where (p_status='all' or s.status=p_status) and (p_kind='all' or s.kind=p_kind)) x
      where p_awaiting_admin is null or (x.j->>'awaiting_admin')::boolean=p_awaiting_admin
      order by x.created_at desc,x.id
      limit p_limit) y),'[]'::jsonb);
end $$;
revoke execute on function admin_v1.support_requests(text,text,boolean,int) from public;
grant execute on function admin_v1.support_requests(text,text,boolean,int) to authenticated;

-- 詳情：案件與往來紀錄（舊到新；原始內容是第一則，id 是案件編號，channel
-- 是來源 web 或 email）。
create function admin_v1.support_request(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r private.support_requests;
begin
  perform private.require_admin();
  if p_id is null then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_id"}';
  end if;
  select * into r from private.support_requests s where s.id=p_id;
  if not found then
    raise sqlstate 'PT404' using message='support.not_found';
  end if;
  return jsonb_build_object('request',private.support_request_json(r),
    'messages',jsonb_build_array(jsonb_build_object('id',r.id,'direction','in','channel',r.source,
        'body',r.message,'created_at',r.created_at,'author',null,
        'from_email',case when r.source='email' then r.contact_email end,
        'suspicious',r.suspicious,'spf',r.mail_spf,'dkim',r.mail_dkim,'attachments',to_jsonb(r.mail_attachments),
        'to_email',null,'delivery_status',null,'attempts',0,'sent_at',null,'send_error',null))
      ||coalesce((select jsonb_agg(private.support_message_json(m) order by m.created_at,m.id)
        from private.support_messages m where m.request_id=r.id),'[]'::jsonb));
end $$;
revoke execute on function admin_v1.support_request(uuid) from public;
grant execute on function admin_v1.support_request(uuid) to authenticated;

-- 回覆：只限 open 且可以回覆的案件；存下內文，交易提交後由 support-mail 寄出
-- （From support@、Reply-To reply+<token>@、附案件連結），寄送結果記在這則。
-- 每案件每台灣日 10 則、總計 50 則。稽核不記內文與 email。
create function admin_v1.reply_support_request(p_id uuid,p_body text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_body text:=btrim(coalesce(p_body,''));
  r private.support_requests;
  v_to text;
  m private.support_messages;
begin
  perform private.require_admin();
  if p_id is null or char_length(v_body) not between 1 and 4000 then
    raise sqlstate 'PT400' using message='request.invalid';
  end if;
  select * into r from private.support_requests s where s.id=p_id for update;
  if not found then
    raise sqlstate 'PT404' using message='support.not_found';
  end if;
  if r.status<>'open' then
    raise sqlstate 'PT409' using message='support.already_resolved';
  end if;
  v_to:=private.support_reply_to(r);
  if v_to is null then
    raise sqlstate 'PT409' using message='support.reply_not_allowed';
  end if;
  if (select count(*) from private.support_messages x where x.request_id=p_id and x.direction='out'
        and x.created_at>=public.report_day_start())>=10
     or (select count(*) from private.support_messages x where x.request_id=p_id and x.direction='out')>=50 then
    raise sqlstate 'PT429' using message='support.reply_limited';
  end if;
  insert into private.support_messages(request_id,direction,channel,body,author,to_email,delivery_status)
    values(p_id,'out','admin',v_body,auth.uid(),v_to,'queued')
    returning * into m;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'reply_support_request','support_requests',p_id::text,null,
      jsonb_build_object('message_id',m.id),'');
  begin
    perform public.support_mail_tick();
  exception when others then
    null;
  end;
  return private.support_message_json(m);
end $$;
revoke execute on function admin_v1.reply_support_request(uuid,text) from public;
grant execute on function admin_v1.reply_support_request(uuid,text) to authenticated;
