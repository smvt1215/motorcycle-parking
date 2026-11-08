-- 管理站「待處理」：有期限的客服案件與內容檢舉合成一個清單（timed_cases）
-- 與計數（timed_case_counts）。唯讀；寫入、5／10 秒排程與取消在之後的 PR
-- （使用者 2026-11-08 決定 Q-timed-01＝A：伺服器單一排程）。計畫見
-- scratch/timed-cases-plan-20261108.md（PR-A）。
--
-- 1. 每一列是一件要處理的事，不含使用者寫的文字與 email（v43：清單列沒有
--    使用者文字）：
--    - 客服：status='open' 的 private.support_requests 一案一列。
--    - 檢舉：處理中的 inappropriate 檢舉，同一點同一 target 一列（和
--      admin_v1.content_report、resolve_content_report 的分組相同），id 是組內
--      最早的一則。
-- 2. 期限 due_at：沿用 #301 的 private.support_due_at()（public.holidays 的
--    5 個工作天）。客服＝送出或重新開啟時間（和 support_request_json 相同）；
--    檢舉＝組內最早一則的時間。
-- 3. state：
--    客服 send_failed（最後一則回覆寄送失敗且不再自動重試）、system（不能
--    回覆：刪除帳號或個資請求未確認本人，由系統處理）、awaiting_admin（最後
--    一則是對方的或還沒有往來）、awaiting_user（最後一則是我們的回覆）。
--    檢舉 spot_deleted（點位已被刪除）、held（被檢舉的部分目前遮蔽中）、
--    open（沒有遮蔽：other，或命中不立即隱藏的規則）。
-- 4. bucket：waiting（awaiting_user、system）、overdue（已過期限）、today
--    （期限是今天結束，台灣時間）、later。rank：send_failed 0（固定在最上面，
--    v43 #6）、overdue 1、today／later 2、waiting 3。
-- 5. 排序 rank、due_at、id；分頁用 keyset cursor {rank,due_at,id}，不用
--    offset。p_bucket all＝overdue＋today＋later（不含 waiting），和
--    timed_case_counts 的 all 一致。
-- 6. version：之後的寫入（PR-B）在排程與執行時各比一次，不符回 409。客服＝
--    案件狀態與往來紀錄最後的時間（private.support_case_version）；檢舉＝
--    community_spots.updated_at（resolve_content_report 的
--    p_expected_updated_at）。

-- ===== 1. 共用判斷 =====
-- 期限分到哪一格：p_now 的台灣日期結束前到期算 today。
create function private.timed_bucket(p_due timestamptz,p_now timestamptz) returns text
language sql stable set search_path='' as $$
  select case
    when p_due<=p_now then 'overdue'
    when p_due<=(((p_now at time zone 'Asia/Taipei')::date+1)::timestamp at time zone 'Asia/Taipei') then 'today'
    else 'later' end;
$$;

-- 客服案件的版本：狀態變更與最後一則往來紀錄的時間（寄送結果不算，寄出
-- 不該讓別人的回覆變成過期）。
create function private.support_case_version(s private.support_requests) returns timestamptz
language sql stable security definer set search_path='' as $$
  select greatest(s.created_at,s.reopened_at,s.resolved_at,s.confirmed_at,s.cancelled_at,
    (select max(m.created_at) from private.support_messages m where m.request_id=s.id));
$$;

-- 所有待處理的列（未排序、未分頁）。p_now 給測試用。
create function private.timed_case_rows(p_now timestamptz default now())
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
  select u.type,u.id,u.kind,u.state,u.due_at,b.bucket,
    case when u.state='send_failed' then 0 when b.bucket='waiting' then 3 when b.bucket='overdue' then 1 else 2 end,
    u.version,u.last_activity_at,u.suspicious,u.report_count,u.hidden_parts,u.spot_id
  from unioned u
  cross join lateral (select case when u.state in ('awaiting_user','system') then 'waiting'
    else private.timed_bucket(u.due_at,p_now) end bucket) b;
$$;

-- p_kind 的值：all、support、report，或 support:<類型>、report:<target>。
create function private.timed_kind_ok(p_kind text) returns boolean
language sql immutable set search_path='' as $$
  select p_kind in ('all','support','report')
    or p_kind in (select 'support:'||k from unnest(array['general','data_issue','complaint','privacy','account_deletion']) k)
    or p_kind in (select 'report:'||t from unnest(array['rider_name','spot_name','text','impersonation','other']) t);
$$;

create function private.timed_kind_match(p_kind text,p_type text,p_row_kind text) returns boolean
language sql immutable set search_path='' as $$
  select p_kind='all' or p_kind=p_type or p_kind=p_type||':'||p_row_kind;
$$;

revoke execute on function private.timed_bucket(timestamptz,timestamptz),
  private.support_case_version(private.support_requests),private.timed_case_rows(timestamptz),
  private.timed_kind_ok(text),private.timed_kind_match(text,text,text)
  from public,anon,authenticated,service_role;

-- ===== 2. 清單 =====
create function admin_v1.timed_cases(p_kind text default 'all',p_bucket text default 'all',
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
      if jsonb_typeof(p_cursor)<>'object' or jsonb_typeof(p_cursor->'rank')<>'number'
         or jsonb_typeof(p_cursor->'due_at')<>'string' or jsonb_typeof(p_cursor->'id')<>'string' then
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
      'hidden_parts',to_jsonb(n.hidden_parts),'spot_id',n.spot_id)
      order by n.n) filter (where n.n<=p_limit),'[]'::jsonb),
    coalesce(bool_or(n.n>p_limit),false)
  into v_items,v_more from numbered n;
  return jsonb_build_object('items',v_items,'next_cursor',case when v_more then
    jsonb_build_object('rank',v_items->-1->'rank','due_at',v_items->-1->'due_at','id',v_items->-1->'id') end);
end $$;
revoke execute on function admin_v1.timed_cases(text,text,jsonb,integer) from public;
grant execute on function admin_v1.timed_cases(text,text,jsonb,integer) to authenticated;

-- ===== 3. 計數 =====
-- all＝overdue＋today＋later（waiting 另計）；send_failed 也算在 all 和它的
-- bucket 裡。by_kind 只算 all 的列。
create function admin_v1.timed_case_counts() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v jsonb;
begin
  perform private.require_admin();
  with rows as (select * from private.timed_case_rows())
  select jsonb_build_object(
    'all',count(*) filter (where bucket<>'waiting'),
    'overdue',count(*) filter (where bucket='overdue'),
    'today',count(*) filter (where bucket='today'),
    'later',count(*) filter (where bucket='later'),
    'waiting',count(*) filter (where bucket='waiting'),
    'send_failed',count(*) filter (where state='send_failed'),
    'by_kind',coalesce((select jsonb_object_agg(k,n) from (
        select type k,count(*) n from rows where bucket<>'waiting' group by type
        union all
        select type||':'||kind,count(*) from rows where bucket<>'waiting' group by type,kind) x),'{}'::jsonb),
    'as_of',now())
  into v from rows;
  return v;
end $$;
revoke execute on function admin_v1.timed_case_counts() from public;
grant execute on function admin_v1.timed_case_counts() to authenticated;
