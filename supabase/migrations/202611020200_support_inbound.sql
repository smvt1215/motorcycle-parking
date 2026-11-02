-- 收信進客服案件（#295 第 2 層；使用者決定 PM_ANS_20261101_144、_147）。
-- Cloudflare Email Routing 把 support@ 與 reply+*@ 交給 Email Worker
-- （workers/support-inbound），Worker 把信轉成 JSON、以共享密鑰 HMAC 簽章
-- 後 POST 給 Edge Function support-inbound，再由它呼叫這裡。原始信件不落地。
--
-- 1. support@：開新案件（一般問題、來源 email）。
-- 2. reply+<token>@：依 token 雜湊找案件；寄件人（信頭 From）必須等於案件
--    email（private.support_reply_to），不符或 token 不對就開新案件。
--    - 案件 open：接到同一案件。
--    - 已結案（done、rejected）30 天內：重新開啟同一案件。
--    - 結案超過 30 天或系統判定的終止狀態：開新案件，related_to 指向舊案。
-- 3. SPF／DKIM 由 Worker 取 Cloudflare 自己加的 Authentication-Results；
--    任一沒有 pass 就標記可疑（suspicious），不寄回條（避免替冒名寄件人
--    產生回信）。附件只記檔名。
-- 4. 次數上限：每個寄件人開新案件每台灣日 3 筆、30 天 10 筆（與表單的聯絡
--    email 合計）；每案件的回信與案件連結補充合計每台灣日 10 則、總計 50
--    則（private.support_add_inbound）。
-- 5. 同一封信（Message-ID）只收一次；鍵只存 SHA-256，30 天後清掉。
-- 6. 刪除帳號與個資權利請求從 email 進來不算本人確認：Edge Function 依內容
--    判斷後，在回條中請對方改用客服表單、由登入 email 的一次性連結確認
--    （和帳號有關的信只寄到登入 email，#285）。

create table private.support_inbound_keys (
  key_hash bytea primary key check (octet_length(key_hash)=32),
  created_at timestamptz not null default now()
);
alter table private.support_inbound_keys enable row level security;
revoke all on private.support_inbound_keys from public,anon,authenticated,service_role;
comment on table private.support_inbound_keys is
  '已收過的信（Message-ID 的 SHA-256，#295）：同一封信只登錄一次；30 天後清除。';

-- p_reply_hash：收件人是 reply+<token>@ 時 token 的雜湊，support@ 時 null。
-- p_link_hash、p_new_reply_hash：開新案件時回條用的案件連結與 Reply-To token
-- 雜湊（Edge Function 每封都產生）。
-- 回傳 result：
--   created     開了新案件（id；related_to：結案太久的舊案）
--   appended    接到既有案件（id、message_id、reopened）
--   duplicate   同一封信已收過
--   rate_limited 超過次數上限，不登錄
create function public.support_inbound(p_reply_hash text,p_from text,p_subject text,p_body text,
  p_spf text,p_dkim text,p_attachments text[],p_key_hash text,p_link_hash text,p_new_reply_hash text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_from text:=lower(btrim(coalesce(p_from,'')));
  v_subject text:=left(btrim(coalesce(p_subject,'')),200);
  v_body text:=left(btrim(coalesce(p_body,'')),4000);
  v_spf text:=case when p_spf in ('pass','fail','softfail','neutral','none','temperror','permerror','policy') then p_spf end;
  v_dkim text:=case when p_dkim in ('pass','fail','softfail','neutral','none','temperror','permerror','policy') then p_dkim end;
  v_suspicious boolean;
  v_attachments text[]:=coalesce((select array_agg(left(a,200)) from unnest(p_attachments[1:20]) a
    where btrim(a)<>''),'{}');
  t private.support_case_tokens;
  r private.support_requests;
  v_related uuid;
  v_out jsonb;
  v_id uuid;
  v_day timestamptz:=public.report_day_start();
begin
  if char_length(v_from) not between 3 and 254 or v_from !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     or p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$'
     or p_link_hash is null or p_link_hash !~ '^[0-9a-f]{64}$'
     or p_new_reply_hash is null or p_new_reply_hash !~ '^[0-9a-f]{64}$'
     or (p_reply_hash is not null and p_reply_hash !~ '^[0-9a-f]{64}$') then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  v_suspicious:=coalesce(v_spf,'')<>'pass' or coalesce(v_dkim,'')<>'pass';
  if v_body='' then v_body:='（沒有純文字內容）'; end if;
  -- 同一封信只收一次。
  insert into private.support_inbound_keys(key_hash) values(decode(p_key_hash,'hex'))
    on conflict do nothing;
  if not found then return jsonb_build_object('result','duplicate'); end if;

  if p_reply_hash is not null then
    select * into t from private.support_case_tokens k
      where k.token_hash=decode(p_reply_hash,'hex') and k.kind='reply';
    if found then
      select * into r from private.support_requests s where s.id=t.request_id for update;
      -- 寄件人必須是案件 email；不符就當成新的來信。
      if private.support_reply_to(r)=v_from then
        if r.status='open' or private.support_reopenable(r) then
          v_out:=private.support_add_inbound(r.id,'email',v_body,v_from,v_spf,v_dkim,v_suspicious,v_attachments);
          if v_out->>'result'='received' then
            return jsonb_build_object('result','appended','id',r.id,'message_id',v_out->'message_id',
              'reopened',v_out->'reopened','suspicious',v_suspicious);
          elsif v_out->>'result'='rate_limited' then
            return jsonb_build_object('result','rate_limited');
          end if;
        end if;
        -- 結案超過 30 天或系統判定的終止狀態：開新案件並指向舊案。
        v_related:=r.id;
      end if;
    end if;
  end if;

  -- 新案件：每個寄件人每台灣日 3 筆、30 天 10 筆（與表單的聯絡 email 合計）。
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||v_from,0));
  if (select count(*) from private.support_requests s where s.contact_email=v_from and s.created_at>=v_day)>=3
     or (select count(*) from private.support_requests s
       where s.contact_email=v_from and s.created_at>=now()-interval '30 days')>=10 then
    return jsonb_build_object('result','rate_limited');
  end if;
  insert into private.support_requests(kind,source,contact_email,subject,message,mail_spf,mail_dkim,
      mail_attachments,suspicious,related_to)
    values('general','email',v_from,v_subject,v_body,v_spf,v_dkim,v_attachments,v_suspicious,v_related)
    returning id into v_id;
  insert into private.support_case_tokens(token_hash,request_id,kind,expires_at)
    values(decode(p_link_hash,'hex'),v_id,'link',now()+interval '30 days'),
          (decode(p_new_reply_hash,'hex'),v_id,'reply',null);
  return jsonb_build_object('result','created','id',v_id,'related_to',v_related,'suspicious',v_suspicious);
exception when check_violation or not_null_violation or unique_violation then
  raise exception 'request.invalid' using errcode='22023';
end $$;
revoke execute on function public.support_inbound(text,text,text,text,text,text,text[],text,text,text)
  from public,anon,authenticated;
grant execute on function public.support_inbound(text,text,text,text,text,text,text[],text,text,text)
  to service_role;

-- 保存期：與 202611020100 相同，另外清掉 30 天前的收信鍵。
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
  delete from private.support_inbound_keys k where k.created_at<now()-interval '30 days';
  delete from private.support_requests s where s.resolved_at<now()-interval '180 days';
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke execute on function public.support_requests_prune() from public,anon,authenticated;
