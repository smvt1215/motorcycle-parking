-- #295：保留收信的 DMARC 結果，排查 spf=none（S-630F13C7）。
--
-- suspicious 的判斷已經看 DMARC，但結果沒有存下來，事後查不到。這裡在案件和
-- 回信都存下 DMARC，並在 admin_v1.support_request 回傳，管理站可查。
-- 判斷規則不變：SPF、DKIM、DMARC 都要 pass。

alter table private.support_requests
  add column mail_dmarc text check (mail_dmarc in ('pass','fail','softfail','neutral','none','temperror','permerror','policy'));
alter table private.support_messages
  add column dmarc text check (dmarc in ('pass','fail','softfail','neutral','none','temperror','permerror','policy'));

create or replace function public.support_inbound(p_reply_hash text,p_from text,p_subject text,p_body text,
  p_spf text,p_dkim text,p_attachments text[],p_key_hash text,p_link_hash text,p_new_reply_hash text,
  p_dmarc text default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_from text:=lower(btrim(coalesce(p_from,'')));
  v_subject text:=left(btrim(coalesce(p_subject,'')),200);
  v_body text:=left(btrim(coalesce(p_body,'')),4000);
  v_spf text:=case when p_spf in ('pass','fail','softfail','neutral','none','temperror','permerror','policy') then p_spf end;
  v_dkim text:=case when p_dkim in ('pass','fail','softfail','neutral','none','temperror','permerror','policy') then p_dkim end;
  v_dmarc text:=case when p_dmarc in ('pass','fail','softfail','neutral','none','temperror','permerror','policy') then p_dmarc end;
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
  v_suspicious:=coalesce(v_spf,'')<>'pass' or coalesce(v_dkim,'')<>'pass' or coalesce(p_dmarc,'')<>'pass';
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
            update private.support_messages m set dmarc=v_dmarc
              where m.id=(v_out->>'message_id')::uuid;
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

  -- 新案件：每個寄件人每台灣日 3 筆、30 天 10 筆（與表單的聯絡 email 合計，
  -- 可疑的信不算）；可疑的另外每個寄件人每日 3 筆、全部每日 50 筆。
  perform pg_advisory_xact_lock(hashtextextended('support-email:'||v_from,0));
  if v_suspicious then
    perform pg_advisory_xact_lock(hashtextextended('support-suspicious',0));
    if (select count(*) from private.support_requests s where s.suspicious and s.source='email'
          and s.contact_email=v_from and s.created_at>=v_day)>=3
       or (select count(*) from private.support_requests s where s.suspicious and s.source='email'
          and s.created_at>=v_day)>=50 then
      return jsonb_build_object('result','rate_limited');
    end if;
  elsif (select count(*) from private.support_requests s where s.contact_email=v_from and not s.suspicious
         and s.created_at>=v_day)>=3
     or (select count(*) from private.support_requests s where s.contact_email=v_from and not s.suspicious
       and s.created_at>=now()-interval '30 days')>=10 then
    return jsonb_build_object('result','rate_limited');
  end if;
  insert into private.support_requests(kind,source,contact_email,subject,message,mail_spf,mail_dkim,mail_dmarc,
      mail_attachments,suspicious,related_to)
    values('general','email',v_from,v_subject,v_body,v_spf,v_dkim,v_dmarc,v_attachments,v_suspicious,v_related)
    returning id into v_id;
  insert into private.support_case_tokens(token_hash,request_id,kind,expires_at)
    values(decode(p_link_hash,'hex'),v_id,'link',now()+interval '30 days'),
          (decode(p_new_reply_hash,'hex'),v_id,'reply',null);
  return jsonb_build_object('result','created','id',v_id,'related_to',v_related,'suspicious',v_suspicious);
exception when check_violation or not_null_violation or unique_violation then
  raise exception 'request.invalid' using errcode='22023';
end $$;

create or replace function private.support_message_json(m private.support_messages) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',m.id,'direction',m.direction,'channel',m.channel,'body',m.body,
    'created_at',m.created_at,'author',m.author,'from_email',m.from_email,'suspicious',m.suspicious,
    'spf',m.spf,'dkim',m.dkim,'dmarc',m.dmarc,'attachments',to_jsonb(m.attachments),
    'to_email',m.to_email,'delivery_status',m.delivery_status,'attempts',m.attempts,
    'sent_at',m.sent_at,'send_error',m.send_error);
$$;

create or replace function admin_v1.support_request(p_id uuid)
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
        'suspicious',r.suspicious,'spf',r.mail_spf,'dkim',r.mail_dkim,'dmarc',r.mail_dmarc,
        'attachments',to_jsonb(r.mail_attachments),
        'to_email',null,'delivery_status',null,'attempts',0,'sent_at',null,'send_error',null))
      ||coalesce((select jsonb_agg(private.support_message_json(m) order by m.created_at,m.id)
        from private.support_messages m where m.request_id=r.id),'[]'::jsonb));
end $$;
