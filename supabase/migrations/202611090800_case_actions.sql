-- 管理站「待處理」的伺服器排程動作（使用者 2026-11-08 決定 Q-timed-01＝A：
-- 一般動作 5 秒、不可逆動作 10 秒；計畫見 scratch/timed-cases-plan-20261108.md
-- 第 1.3、2、3、4、5 節與第 9 節 PR-B）。既有的 reply_support_request、
-- resolve_support_request、resolve_content_report 不改；這裡只決定「何時」呼叫
-- 它們。
--
-- 1. 佇列（private.case_actions）：每個動作一列、各自倒數。通用佇列的形狀
--    （使用者 2026-11-09 決定，#390）：日後換成自架 Worker 時只換執行者。
--    - 業務規則全部在 private.run_due_case_actions()；Edge Function case-actions
--      與 pg_cron 只呼叫它（public.run_due_case_actions 只是給 service_role 的
--      入口，private 沒有開放給 PostgREST）。
--    - dedupe_key（unique）＝案件＋動作＋版本＋內容雜湊：同一動作重送不會排
--      兩次；內容不同（例如連續兩則不同的回覆）是兩個動作，後者在執行時會因
--      版本已變而 stale，草稿留著。取消、stale、失敗時清掉，之後可以再排。
--    - leased_until：running 超過租約視為中斷，可以重新領取（仍比對版本）。
--      現在的執行者一個交易做完「領取＋比對＋執行＋結果」：中途掛掉會回滾成
--      scheduled，副作用（寫入回覆、pg_net 排程）和狀態一起生效，不會做一半。
--      租約是給之後會先提交領取、再執行的執行者（自架 Worker）用的。
-- 2. 排程（schedule_case_action）：先比一次版本，再以同一套函式「試跑後回滾」，
--    欄位、權限、上限錯誤當場回給管理員（不另寫一份規則）。執行時再比一次。
-- 3. 觸發：寫入後用 pg_net 叫 Edge Function，等到 run_at 再執行（交易提交後才
--    真的送出）；pg_cron 每分鐘兜底，最多晚 1 分鐘。
-- 4. 執行者沒有管理員的 JWT：以動作建立者的身分（這個交易內的
--    request.jwt.claims）呼叫既有函式，稽核仍記建立者；建立者已不是管理員時
--    不執行。
-- 5. 待處理清單：timed_case_rows 看每案最新一個動作（scheduled／running →
--    state scheduled；failed → send_failed，rank 0）；timed_cases 多
--    pending_action（不含內文）。
-- 6. 保存：done、cancelled 當下清掉 payload（回覆內文的正本在
--    support_messages），stale、failed 留著還原草稿；結束滿 30 天整列刪除。

-- ===== 1. 資料 =====
create table private.case_actions (
  id uuid primary key default gen_random_uuid(),
  case_type text not null check (case_type in ('support','report')),
  -- timed_cases 的 id：客服案件 id，或檢舉組內最早一則的 id。
  case_id text not null,
  action text not null check (action in ('reply','resolve_support','report_restore','report_keep','report_edit')),
  -- reply {body}；resolve_support {status,note}；report_* {patch,reason,note}。
  payload jsonb not null default '{}' check (jsonb_typeof(payload)='object'),
  -- 點位已不存在的檢舉沒有版本（null）。
  expected_version timestamptz,
  actor uuid not null,
  run_at timestamptz not null,
  irreversible boolean not null,
  status text not null default 'scheduled'
    check (status in ('scheduled','running','done','cancelled','failed','stale')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  -- 穩定錯誤碼或 SQLSTATE，不含使用者文字。
  error text check (char_length(error)<=200),
  -- 實際時間：同一交易裡的幾筆也分得出先後。
  created_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  finished_at timestamptz,
  leased_until timestamptz,
  dedupe_key text unique,
  -- reply 建立的那則回覆（「再寄一次」用）。
  message_id uuid references private.support_messages(id) on delete set null
);
create index case_actions_due_idx on private.case_actions(run_at) where status='scheduled';
create index case_actions_lease_idx on private.case_actions(leased_until) where status='running';
create index case_actions_case_idx on private.case_actions(case_type,case_id,created_at desc);
create index case_actions_message_idx on private.case_actions(message_id) where message_id is not null;
alter table private.case_actions enable row level security;
revoke all on private.case_actions from public,anon,authenticated,service_role;
comment on table private.case_actions is
  '管理站的排程動作（5／10 秒內可取消）。領取用 for update skip locked；規則在 private.run_due_case_actions()。';

-- 秒數與上限集中在這裡，改值只動一處。
create function private.case_action_delay(p_irreversible boolean) returns interval
language sql immutable set search_path='' as $$
  select case when p_irreversible then interval '10 seconds' else interval '5 seconds' end;
$$;
create function private.case_action_lease() returns interval
language sql immutable set search_path='' as $$ select interval '60 seconds' $$;
-- hold 每次最多延 60 秒、累計最多 5 分鐘，避免永遠不執行。
create function private.case_action_hold_step() returns interval
language sql immutable set search_path='' as $$ select interval '60 seconds' $$;
create function private.case_action_hold_cap() returns interval
language sql immutable set search_path='' as $$ select interval '5 minutes' $$;

create function private.case_action_type(p_action text) returns text
language sql immutable set search_path='' as $$
  select case when p_action in ('reply','resolve_support') then 'support'
    when p_action in ('report_restore','report_keep','report_edit') then 'report' end;
$$;

create function private.is_uuid(p_text text) returns boolean
language sql immutable set search_path='' as $$
  select coalesce(p_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false);
$$;

-- 案件目前的狀態與版本（timed_cases 的 version）。
create function private.case_current(p_type text,p_id text,
  out case_found boolean,out is_open boolean,out version timestamptz,out changed_by text)
language plpgsql stable security definer set search_path='' as $$
declare s private.support_requests; q public.moderation_queue;
begin
  case_found:=false;
  if p_type='support' then
    select * into s from private.support_requests r where r.id=p_id::uuid;
    if s.id is null then return; end if;
    case_found:=true;
    is_open:=s.status='open';
    version:=private.support_case_version(s);
    changed_by:=case when (select m.direction from private.support_messages m where m.request_id=s.id
      order by m.created_at desc,m.id desc limit 1)='in' then 'user_reply' else 'other_admin' end;
  else
    select * into q from public.moderation_queue m where m.id=p_id::uuid and m.field='inappropriate';
    if q.id is null then return; end if;
    case_found:=true;
    is_open:=q.resolved_at is null;
    select c.updated_at into version from public.community_spots c where c.id::text=q.source_id;
    changed_by:='spot_edited';
  end if;
end $$;

-- 鎖住案件（順序和 resolve_content_report 相同：先檢舉、後點位）。
create function private.case_lock(p_type text,p_id text) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
  if p_type='support' then
    perform 1 from private.support_requests r where r.id=p_id::uuid for update;
  else
    perform 1 from public.moderation_queue m where m.id=p_id::uuid and m.field='inappropriate' for update;
    perform 1 from public.community_spots c
      where c.id::text=(select m.source_id from public.moderation_queue m where m.id=p_id::uuid) for update;
  end if;
end $$;

-- 以動作建立者的身分呼叫既有函式：唯一的一份規則。request.jwt.claims 只在
-- 這個交易內有效，由呼叫端還原。
create function private.case_action_apply(a private.case_actions) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a.actor,'role','authenticated','aal','aal2',
    'app_metadata',jsonb_build_object('role','admin'))::text,true);
  if a.action='reply' then
    return admin_v1.reply_support_request(a.case_id::uuid,a.payload->>'body');
  elsif a.action='resolve_support' then
    return admin_v1.resolve_support_request(a.case_id::uuid,a.payload->>'status',coalesce(a.payload->>'note',''));
  end if;
  -- 點位已不存在時沒有版本可比，resolve_content_report 不看這個值。
  return admin_v1.resolve_content_report(a.case_id,substr(a.action,8),coalesce(a.expected_version,now()),
    a.payload->'patch',a.payload->>'reason',coalesce(a.payload->>'note',''));
end $$;

-- 用 pg_net 叫 Edge Function，等到 p_run_at 執行。交易提交後才真的送出；沒有
-- vault 設定時不做事，由 pg_cron 兜底。
create function private.case_action_tick(p_run_at timestamptz) returns bigint
language plpgsql security definer set search_path='' as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='case_actions_secret';
  if v_url is null or v_secret is null or v_url !~ '^https://' then return null; end if;
  return net.http_post(
    url:=rtrim(v_url,'/')||'/functions/v1/case-actions',
    headers:=jsonb_build_object('Content-Type','application/json','x-case-actions-secret',v_secret),
    body:=jsonb_build_object('run_at',p_run_at),
    timeout_milliseconds:=30000);
end $$;

create function private.case_action_receipt(a private.case_actions,p_duplicate boolean) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('action_id',a.id,'run_at',a.run_at,'irreversible',a.irreversible,'duplicate',p_duplicate);
$$;

-- ===== 2. 執行 =====
-- 到期的列一批（最多 p_limit，預設 20）：for update skip locked 領取，兩個執行
-- 者不會領到同一列。每一列在自己的子交易裡比對版本並執行；一列失敗不影響其他列。
-- 暫時性錯誤（死結、等鎖逾時）放回 scheduled，下一輪再做，attempts 仍累計。
create function private.run_due_case_actions(p_limit integer default 20) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='5s' as $$
declare
  v_claims text:=current_setting('request.jwt.claims',true);
  a private.case_actions;
  v_cur record;
  v_out jsonb;
  v_status text;
  v_error text;
  v_code text;
  v_msg text;
  v_claimed integer:=0;
  v_done integer:=0;
  v_stale integer:=0;
  v_failed integer:=0;
  v_retried integer:=0;
begin
  for a in
    select c.* from private.case_actions c
    where (c.status='scheduled' and c.run_at<=now()) or (c.status='running' and c.leased_until<=now())
    order by c.run_at,c.id
    limit greatest(1,least(coalesce(p_limit,20),100))
    for update of c skip locked
  loop
    v_claimed:=v_claimed+1;
    v_out:=null;
    v_error:=null;
    if a.attempts>=5 then
      v_status:='failed';
      v_error:='case_action.attempts_exhausted';
    else
      -- 從這裡起不能取消。
      update private.case_actions c
        set status='running',attempts=c.attempts+1,started_at=now(),leased_until=now()+private.case_action_lease(),error=null
        where c.id=a.id;
      begin
        perform private.case_lock(a.case_type,a.case_id);
        select * into v_cur from private.case_current(a.case_type,a.case_id);
        if not v_cur.case_found then
          v_status:='failed';
          v_error:='case.not_found';
        elsif not v_cur.is_open or v_cur.version is distinct from a.expected_version then
          v_status:='stale';
        elsif not exists(select 1 from auth.users u where u.id=a.actor and u.deleted_at is null
            and u.raw_app_meta_data->>'role'='admin') then
          v_status:='failed';
          v_error:='case_action.actor_not_admin';
        else
          v_out:=private.case_action_apply(a);
          v_status:='done';
        end if;
      exception when others then
        get stacked diagnostics v_code=returned_sqlstate,v_msg=message_text;
        if v_code in ('40P01','40001','55P03') then
          v_status:='retry';
        else
          v_status:='failed';
          -- 其他錯誤只記 SQLSTATE：訊息可能帶到使用者文字。
          v_error:=left(case when v_code like 'PT%' then v_msg else v_code end,200);
        end if;
      end;
    end if;
    update private.case_actions c set
      status=case v_status when 'retry' then 'scheduled' else v_status end,
      leased_until=null,
      finished_at=case when v_status='retry' then null else now() end,
      error=v_error,
      payload=case when v_status='done' then '{}'::jsonb else c.payload end,
      dedupe_key=case when v_status in ('done','retry') then c.dedupe_key end,
      message_id=case when v_status='done' and a.action='reply' then (v_out->>'id')::uuid else c.message_id end
      where c.id=a.id;
    if v_status='done' then v_done:=v_done+1;
    elsif v_status='stale' then v_stale:=v_stale+1;
    elsif v_status='retry' then v_retried:=v_retried+1;
    else v_failed:=v_failed+1;
    end if;
  end loop;
  perform set_config('request.jwt.claims',coalesce(v_claims,''),true);
  return jsonb_build_object('claimed',v_claimed,'done',v_done,'stale',v_stale,'failed',v_failed,'retried',v_retried);
end $$;

-- 給 Edge Function 的入口（private 沒有開放給 PostgREST），不放任何邏輯。
create function public.run_due_case_actions(p_limit integer default 20) returns jsonb
language sql volatile security definer set search_path='' as $$
  select private.run_due_case_actions(p_limit);
$$;
revoke execute on function public.run_due_case_actions(integer) from public,anon,authenticated;
grant execute on function public.run_due_case_actions(integer) to service_role;

create function private.case_actions_prune() returns integer
language sql volatile security definer set search_path='' as $$
  with d as (delete from private.case_actions c
    where c.status in ('done','cancelled','stale','failed') and c.finished_at<now()-interval '30 days'
    returning 1)
  select count(*)::integer from d;
$$;

revoke execute on function private.case_action_delay(boolean),private.case_action_lease(),
  private.case_action_hold_step(),private.case_action_hold_cap(),private.case_action_type(text),
  private.is_uuid(text),private.case_current(text,text),private.case_lock(text,text),
  private.case_action_apply(private.case_actions),private.case_action_tick(timestamptz),
  private.case_action_receipt(private.case_actions,boolean),private.run_due_case_actions(integer),
  private.case_actions_prune()
  from public,anon,authenticated,service_role;

-- 每分鐘兜底：pg_net 失敗、Edge Function 冷啟動或逾時留下的列。
select cron.schedule('case-actions','* * * * *','select private.run_due_case_actions()');
select cron.schedule('case-actions-prune','53 20 * * *','select private.case_actions_prune()');

-- ===== 3. 管理站 API =====
-- 排程。p_case 是 timed_cases 的 id；p_expected_version 是它的 version。
-- 重送同一個動作（案件、動作、版本、內容都相同）回原本那列，duplicate true。
-- 錯誤：400 request.invalid（field）與既有函式的 400／404／409／429；
-- 409 case.stale（details：{"version":…,"by":"other_admin"|"user_reply"|"spot_edited"}）。
create function admin_v1.schedule_case_action(p_case text,p_action text,p_payload jsonb,p_expected_version timestamptz)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  v_type text:=private.case_action_type(p_action);
  v_payload jsonb:=coalesce(p_payload,'{}'::jsonb);
  v_case text;
  v_key text;
  v_cur record;
  v_irreversible boolean;
  a private.case_actions;
begin
  perform private.require_admin();
  if not private.is_uuid(p_case) then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_case"}';
  end if;
  if v_type is null then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_action"}';
  end if;
  if jsonb_typeof(v_payload)<>'object' or octet_length(v_payload::text)>32768 then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_payload"}';
  end if;
  v_case:=p_case::uuid::text;
  v_key:=v_type||':'||v_case||':'||p_action||':'||coalesce(extract(epoch from p_expected_version)::text,'')
    ||':'||md5(v_payload::text);
  -- 先看重送：第一次已執行、版本已變時，重送不該回 stale。
  select * into a from private.case_actions c where c.dedupe_key=v_key;
  if found then return private.case_action_receipt(a,true); end if;

  select * into v_cur from private.case_current(v_type,v_case);
  if not v_cur.case_found then
    raise sqlstate 'PT404' using message=case v_type when 'support' then 'support.not_found' else 'content_report.not_found' end;
  end if;
  if not v_cur.is_open then
    raise sqlstate 'PT409' using message=case v_type when 'support' then 'support.already_resolved' else 'content_report.already_resolved' end;
  end if;
  if v_cur.version is distinct from p_expected_version then
    raise sqlstate 'PT409' using message='case.stale',
      detail=jsonb_build_object('version',v_cur.version,'by',v_cur.changed_by)::text;
  end if;

  -- 試跑既有函式再回滾（包括 pg_net 的排程）：內容或權限不合當場回錯，不必
  -- 等 5 秒才失敗，也不用另寫一份規則。
  a.case_id:=v_case; a.action:=p_action; a.payload:=v_payload;
  a.expected_version:=p_expected_version; a.actor:=auth.uid();
  begin
    perform private.case_action_apply(a);
    raise sqlstate 'CA000';
  exception when sqlstate 'CA000' then
    null;
  end;

  -- 不可逆：永久清除車友名稱、移除文字、換點名、覆寫內容。寄信與 other 的
  -- 結案（什麼都沒遮蔽、也沒改內容）是一般動作。
  v_irreversible:=p_action='report_edit' or (p_action='report_keep' and (
    cardinality(private.content_hold_parts((select q.proposed->>'target' from public.moderation_queue q where q.id=v_case::uuid)))>0
    or coalesce(v_payload->'patch','{}'::jsonb)<>'{}'::jsonb));

  -- 實際時間，不是交易開始的 now()：試跑等鎖不能吃掉可以取消的秒數。
  insert into private.case_actions(case_type,case_id,action,payload,expected_version,actor,run_at,irreversible,dedupe_key)
    values(v_type,v_case,p_action,v_payload,p_expected_version,auth.uid(),
      clock_timestamp()+private.case_action_delay(v_irreversible),v_irreversible,v_key)
    on conflict (dedupe_key) do nothing
    returning * into a;
  if not found then
    -- 同時送出的另一個請求先寫入了。
    select * into a from private.case_actions c where c.dedupe_key=v_key;
    return private.case_action_receipt(a,true);
  end if;
  begin
    perform private.case_action_tick(a.run_at);
  exception when others then
    null;
  end;
  return private.case_action_receipt(a,false);
end $$;
revoke execute on function admin_v1.schedule_case_action(text,text,jsonb,timestamptz) from public;
grant execute on function admin_v1.schedule_case_action(text,text,jsonb,timestamptz) to authenticated;

-- 取消：只有還沒開始的動作。執行者正領著這一列時，這裡會等它結束，再回
-- case_action.started。
create function admin_v1.cancel_case_action(p_action_id uuid)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare a private.case_actions;
begin
  perform private.require_admin();
  if p_action_id is null then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_action_id"}';
  end if;
  select * into a from private.case_actions c where c.id=p_action_id for update;
  if not found then raise sqlstate 'PT404' using message='case_action.not_found'; end if;
  if a.status<>'cancelled' then
    if a.status<>'scheduled' then raise sqlstate 'PT409' using message='case_action.started'; end if;
    update private.case_actions c
      set status='cancelled',finished_at=now(),payload='{}'::jsonb,dedupe_key=null
      where c.id=p_action_id;
  end if;
  return jsonb_build_object('cancelled',true);
end $$;
revoke execute on function admin_v1.cancel_case_action(uuid) from public;
grant execute on function admin_v1.cancel_case_action(uuid) to authenticated;

-- 暫停倒數（鍵盤焦點、朗讀；v43 #21）。p_hold true：run_at 延到 now()+60 秒，
-- 要繼續暫停就再呼叫；false：重新倒數 5／10 秒。累計上限是原本的時間＋5 分鐘
-- （capped true＝已碰到上限）。
create function admin_v1.hold_case_action(p_action_id uuid,p_hold boolean)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  a private.case_actions;
  v_delay interval;
  v_cap timestamptz;
  v_target timestamptz;
begin
  perform private.require_admin();
  if p_action_id is null or p_hold is null then
    raise sqlstate 'PT400' using message='request.invalid';
  end if;
  select * into a from private.case_actions c where c.id=p_action_id for update;
  if not found then raise sqlstate 'PT404' using message='case_action.not_found'; end if;
  if a.status='cancelled' then raise sqlstate 'PT409' using message='case_action.cancelled'; end if;
  if a.status<>'scheduled' then raise sqlstate 'PT409' using message='case_action.started'; end if;
  v_delay:=private.case_action_delay(a.irreversible);
  v_cap:=a.created_at+v_delay+private.case_action_hold_cap();
  v_target:=now()+case when p_hold then private.case_action_hold_step() else v_delay end;
  update private.case_actions c set run_at=least(v_target,v_cap) where c.id=p_action_id
    returning * into a;
  if not p_hold then
    begin
      perform private.case_action_tick(a.run_at);
    exception when others then
      null;
    end;
  end if;
  return jsonb_build_object('action_id',a.id,'run_at',a.run_at,'capped',v_target>v_cap);
end $$;
revoke execute on function admin_v1.hold_case_action(uuid,boolean) from public;
grant execute on function admin_v1.hold_case_action(uuid,boolean) to authenticated;

-- 再寄一次（只限 reply，立即、不重新等 5 秒，寄送上限不重算）：
-- 寄信失敗（動作 done、回覆 failed）→ 回覆回到 queued、attempts 歸零；
-- 動作本身失敗（還沒有回覆）→ 回到 scheduled、馬上執行。
-- 重寄前比對版本：已結案 support.already_resolved；之後又有往來 case.stale。
create function admin_v1.retry_case_action(p_action_id uuid)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  a private.case_actions;
  m private.support_messages;
  v_cur record;
  v_expected timestamptz;
begin
  perform private.require_admin();
  if p_action_id is null then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_action_id"}';
  end if;
  select * into a from private.case_actions c where c.id=p_action_id for update;
  if not found then raise sqlstate 'PT404' using message='case_action.not_found'; end if;
  if a.action<>'reply' or a.status not in ('failed','done') then
    raise sqlstate 'PT409' using message='case_action.not_retryable';
  end if;
  perform private.case_lock(a.case_type,a.case_id);
  v_expected:=a.expected_version;
  if a.status='done' then
    select * into m from private.support_messages x where x.id=a.message_id for update;
    if m.id is null or m.delivery_status<>'failed' then
      raise sqlstate 'PT409' using message='case_action.not_retryable';
    end if;
    -- 這則回覆本身就是目前的版本。
    v_expected:=m.created_at;
  elsif a.attempts>=5 then
    raise sqlstate 'PT409' using message='case_action.retry_limit';
  end if;
  select * into v_cur from private.case_current(a.case_type,a.case_id);
  if not v_cur.case_found then raise sqlstate 'PT404' using message='support.not_found'; end if;
  if not v_cur.is_open then raise sqlstate 'PT409' using message='support.already_resolved'; end if;
  if v_cur.version is distinct from v_expected then
    raise sqlstate 'PT409' using message='case.stale',
      detail=jsonb_build_object('version',v_cur.version,'by',v_cur.changed_by)::text;
  end if;
  if a.status='done' then
    update private.support_messages x
      set delivery_status='queued',attempts=0,send_error=null,claimed_at=null
      where x.id=m.id;
  else
    update private.case_actions c
      set status='scheduled',run_at=now(),error=null,started_at=null,finished_at=null,leased_until=null
      where c.id=a.id
      returning * into a;
  end if;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'retry_case_action','support_requests',a.case_id,null,
      jsonb_build_object('action_id',a.id,'message_id',a.message_id),'');
  begin
    if m.id is not null then
      perform public.support_mail_tick();
    else
      perform private.case_action_tick(a.run_at);
    end if;
  exception when others then
    null;
  end;
  return jsonb_build_object('action_id',a.id,'run_at',now());
end $$;
revoke execute on function admin_v1.retry_case_action(uuid) from public;
grant execute on function admin_v1.retry_case_action(uuid) to authenticated;

-- 詳情頁：等待中、失敗（含寄信失敗）與 stale 的動作，新的在前。payload 用來
-- 還原草稿。address_editable：目前沒有改地址的 API，一律 false。
create function admin_v1.case_actions(p_case text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform private.require_admin();
  if not private.is_uuid(p_case) then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_case"}';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',x.id,'case_type',x.case_type,'case_id',x.case_id,'action',x.action,'status',x.status,
      'run_at',x.run_at,'irreversible',x.irreversible,'attempts',x.attempts,'error',x.error,
      'actor',x.actor,'expected_version',x.expected_version,'payload',x.payload,
      'created_at',x.created_at,'started_at',x.started_at,'finished_at',x.finished_at,
      'message_id',x.message_id,'delivery_status',x.delivery_status,'send_error',x.send_error,
      'address_editable',false)
      order by x.created_at desc,x.id)
    from (select c.*,m.delivery_status,m.send_error
      from private.case_actions c
      left join private.support_messages m on m.id=c.message_id
      where c.case_id=p_case::uuid::text
        and (c.status in ('scheduled','running','failed','stale') or m.delivery_status='failed')
      order by c.created_at desc,c.id
      limit 50) x),'[]'::jsonb);
end $$;
revoke execute on function admin_v1.case_actions(text) from public;
grant execute on function admin_v1.case_actions(text) to authenticated;

-- ===== 4. 待處理清單 =====
-- 每案最新一個動作：等待中顯示倒數；失敗或 stale 要處理；後來成功或取消就不
-- 顯示。寄信失敗（done 但回覆 failed 且不再重試）也算失敗。不含內文（清單列
-- 沒有使用者文字）。
create function private.case_pending_action(p_type text,p_id text) returns jsonb
language sql stable security definer set search_path='' as $$
  select case when a.status in ('scheduled','running','failed','stale')
      or (a.status='done' and m.delivery_status='failed' and m.attempts>=5) then
    jsonb_build_object('id',a.id,'action',a.action,'run_at',a.run_at,'irreversible',a.irreversible,
      'status',case when a.status='done' then 'failed' else a.status end) end
  from (select * from private.case_actions c where c.case_type=p_type and c.case_id=p_id
    order by c.created_at desc,c.id desc limit 1) a
  left join private.support_messages m on m.id=a.message_id;
$$;
revoke execute on function private.case_pending_action(text,text) from public,anon,authenticated,service_role;

-- 202611090700 加上每案最新的動作：等待中 state 是 scheduled（bucket 不變，
-- 倒數的 5 秒內不會跳到別的分頁）；失敗是 send_failed（rank 0，即使案件在等
-- 對方也回到待處理最上面，v43 #6）。
create or replace function private.timed_case_rows(p_now timestamptz default now())
returns table(type text,id text,kind text,state text,due_at timestamptz,bucket text,rank integer,
  version timestamptz,last_activity_at timestamptz,suspicious boolean,report_count integer,
  hidden_parts text[],spot_id text)
language sql stable security definer set search_path='' as $$
  with support as (
    select s.id::text id,s.kind,
      case
        when lm.direction='out' and lm.delivery_status='failed' and lm.attempts>=5 then 'send_failed'
        when private.support_reply_to(s) is null then 'system'
        when coalesce(lm.direction,'in')='in' then 'awaiting_admin'
        else 'awaiting_user' end state,
      private.support_due_at(coalesce(s.reopened_at,s.created_at)) due_at,
      private.support_case_version(s) version,
      coalesce(lm.created_at,s.reopened_at,s.created_at) last_activity_at,
      s.suspicious or coalesce(sm.suspicious,false) suspicious
    from private.support_requests s
    left join lateral (select m.direction,m.delivery_status,m.attempts,m.created_at
      from private.support_messages m where m.request_id=s.id
      order by m.created_at desc,m.id desc limit 1) lm on true
    left join lateral (select bool_or(m.suspicious) suspicious
      from private.support_messages m where m.request_id=s.id) sm on true
    where s.status='open'
  ), reports as (
    select (array_agg(q.id order by q.created_at,q.id))[1]::text id,q.proposed->>'target' kind,
      q.source_id,min(q.created_at) first_at,max(q.created_at) last_at,count(*)::integer n
    from public.moderation_queue q
    where q.field='inappropriate' and q.resolved_at is null
    group by q.source_id,q.proposed->>'target'
  ), report_rows as (
    select r.id,r.kind,
      case
        when c.id is null or c.deleted_at is not null then 'spot_deleted'
        when private.content_hold_parts(r.kind)&&c.content_held then 'held'
        else 'open' end state,
      private.support_due_at(r.first_at) due_at,c.updated_at version,r.last_at,r.n,
      coalesce(array(select p from unnest(private.content_hold_parts(r.kind)) p
        where p=any(c.content_held) order by p),'{}') hidden,
      r.source_id
    from reports r
    left join public.community_spots c on c.id::text=r.source_id
  ), unioned as (
    select 'support' type,s.id,s.kind,s.state,s.due_at,s.version,s.last_activity_at,s.suspicious,
      null::integer report_count,null::text[] hidden_parts,null::text spot_id
    from support s
    union all
    select 'report',r.id,r.kind,r.state,r.due_at,r.version,r.last_at,false,r.n,r.hidden,r.source_id
    from report_rows r
  )
  select u.type,u.id,u.kind,fs.state,u.due_at,b.bucket,
    case when fs.state='send_failed' then 0 when b.bucket='waiting' then 3 when b.bucket='overdue' then 1 else 2 end,
    u.version,u.last_activity_at,u.suspicious,u.report_count,u.hidden_parts,u.spot_id
  from unioned u
  left join lateral (select a.status from private.case_actions a where a.case_type=u.type and a.case_id=u.id
    order by a.created_at desc,a.id desc limit 1) la on true
  cross join lateral (select case
    when la.status in ('scheduled','running') then 'scheduled'
    when la.status='failed' then 'send_failed'
    else u.state end state) fs
  cross join lateral (select case
    when fs.state in ('awaiting_user','system')
      or (fs.state='scheduled' and u.state in ('awaiting_user','system')) then 'waiting'
    else private.timed_bucket(u.due_at,p_now) end bucket) b;
$$;

-- 202611090700 加上 pending_action。
create or replace function admin_v1.timed_cases(p_kind text default 'all',p_bucket text default 'all',
  p_cursor jsonb default null,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_rank integer; v_due timestamptz; v_id text;
  v_items jsonb; v_more boolean;
begin
  perform private.require_admin();
  if p_kind is null or not private.timed_kind_ok(p_kind) then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_kind"}';
  end if;
  if p_bucket is null or p_bucket not in ('all','overdue','today','later','waiting') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_bucket"}';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_limit"}';
  end if;
  if p_cursor is not null then
    begin
      -- A missing key reads null: is distinct from, not <>.
      if jsonb_typeof(p_cursor) is distinct from 'object'
         or jsonb_typeof(p_cursor->'rank') is distinct from 'number'
         or jsonb_typeof(p_cursor->'due_at') is distinct from 'string'
         or jsonb_typeof(p_cursor->'id') is distinct from 'string' then
        raise sqlstate '22023';
      end if;
      v_rank:=(p_cursor->>'rank')::integer;
      v_due:=(p_cursor->>'due_at')::timestamptz;
      v_id:=p_cursor->>'id';
    exception when others then
      raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_cursor"}';
    end;
  end if;
  with picked as (
    select r.* from private.timed_case_rows() r
    where private.timed_kind_match(p_kind,r.type,r.kind)
      and case p_bucket when 'all' then r.bucket<>'waiting' else r.bucket=p_bucket end
      and (p_cursor is null or (r.rank,r.due_at,r.id)>(v_rank,v_due,v_id))
    order by r.rank,r.due_at,r.id
    limit p_limit+1
  ), numbered as (
    select p.*,row_number() over (order by p.rank,p.due_at,p.id) n from picked p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id',n.id,'type',n.type,'kind',n.kind,'state',n.state,'due_at',n.due_at,'bucket',n.bucket,
      'rank',n.rank,'version',n.version,'last_activity_at',n.last_activity_at,
      'suspicious',n.suspicious,'report_count',n.report_count,
      'hidden_parts',to_jsonb(n.hidden_parts),'spot_id',n.spot_id,
      'pending_action',private.case_pending_action(n.type,n.id))
      order by n.n) filter (where n.n<=p_limit),'[]'::jsonb),
    coalesce(bool_or(n.n>p_limit),false)
  into v_items,v_more from numbered n;
  return jsonb_build_object('items',v_items,'next_cursor',case when v_more then
    jsonb_build_object('rank',v_items->-1->'rank','due_at',v_items->-1->'due_at','id',v_items->-1->'id') end);
end $$;
