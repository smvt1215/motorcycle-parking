-- 管理站「待處理」案件詳情需要的兩個補充（#295 第二層，只做加法）：
-- 1. timed_cases 的每一列多 has_exchange：分辨「等你回覆」（沒有往來）和「對方
--    補充了」（最後一則是對方、之前已有往來）。support_messages 不含原始內容，
--    所以有任何一列就算有往來。檢舉一律 false。
-- 2. admin_v1.timed_case(p_id)：用案件 id 讀一列。案件頁可以從網址直接開啟
--    （/pending/:caseId），寫入要帶的 version 和檢舉的期限只有這份資料有，不能
--    只靠清單目前載入的那幾頁。

create function private.timed_case_extras(p_type text,p_id text) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'pending_action',private.case_pending_action(p_type,p_id),
    'has_exchange',p_type='support' and exists(select 1 from private.support_messages m where m.request_id=p_id::uuid));
$$;
revoke execute on function private.timed_case_extras(text,text) from public,anon,authenticated,service_role;

-- 202611090800 加上 has_exchange；其餘不變。
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
      'hidden_parts',to_jsonb(n.hidden_parts),'spot_id',n.spot_id)
      ||private.timed_case_extras(n.type,n.id)
      order by n.n) filter (where n.n<=p_limit),'[]'::jsonb),
    coalesce(bool_or(n.n>p_limit),false)
  into v_items,v_more from numbered n;
  return jsonb_build_object('items',v_items,'next_cursor',case when v_more then
    jsonb_build_object('rank',v_items->-1->'rank','due_at',v_items->-1->'due_at','id',v_items->-1->'id') end);
end $$;

-- 用 id 讀一列（timed_cases 的同一份資料）。案件已結束或不是待處理的 id 回
-- 404 case.not_found。檢舉要用組內最早一則的 id（timed_cases 的 id）。
create function admin_v1.timed_case(p_id text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v jsonb;
begin
  perform private.require_admin();
  if not private.is_uuid(p_id) then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_id"}';
  end if;
  select to_jsonb(r)||private.timed_case_extras(r.type,r.id) into v
    from private.timed_case_rows() r where r.id=p_id::uuid::text;
  if v is null then raise sqlstate 'PT404' using message='case.not_found'; end if;
  return v;
end $$;
revoke execute on function admin_v1.timed_case(text) from public;
grant execute on function admin_v1.timed_case(text) to authenticated;
