-- #280：隱藏的車友跟著帳號（使用者決定 PM_ANS_20261102_164 第 5 點；形狀依
-- APPIMPL_REQ_20261102_35），以及收藏頁依 id 批次讀點位（APPIMPL_ANS_20261102_33）。
--
-- 1. private.hidden_riders：本人的隱藏清單（代號、隱藏當下看到的名稱與點位
--    名稱、隱藏時間）。只經 api_v1 存取，函式以 auth.uid() 限本人；帳號刪除時
--    cascade 一併刪除（#270 的刪除流程不用改）。不檢查代號是否存在：清單不能
--    拿來探測代號，對方刪帳號後代號本來就失效。
--    hidden_riders_list()、hidden_riders_merge(items)（聯集；同一代號保留較早
--    的 hidden_at 與當時的名稱；回傳合併後完整清單，單筆新增也用它）、
--    hidden_riders_remove(handle)，都回 {items, limit}。每帳號最多 500 筆：合併後超過時整批不寫入，
--    回 400 hidden_riders.too_many。要 Google／Apple 登入（匿名登入 401）。
-- 2. api_v1.spots_by_ids(ids)：一次最多 200 個 id；社群點（uuid）與官方點
--    （official:<uuid>）照 public_spots 與官方點的 RLS，看不到或認不得的 id
--    不回傳；每列形狀同 spots_in_viewport。

-- ===== 1. 隱藏清單 =====
create table private.hidden_riders (
  user_id uuid not null references auth.users(id) on delete cascade,
  handle text not null check (handle ~ '^[0-9a-f]{32}$'),
  name_at_hide text not null default '' check (char_length(name_at_hide)<=40),
  spot_name_at_hide text not null default '' check (char_length(spot_name_at_hide)<=100),
  hidden_at timestamptz not null,
  primary key (user_id,handle)
);
revoke all on private.hidden_riders from public,anon,authenticated,service_role;
comment on table private.hidden_riders is
  '本人隱藏的車友（#280）：只經 api_v1.hidden_riders_*；帳號刪除時一併刪除。';

create function private.hidden_riders_limit() returns int
language sql immutable security definer set search_path='' as $$ select 500 $$;
revoke execute on function private.hidden_riders_limit() from public,anon,authenticated,service_role;

create function private.hidden_riders_of(p_user uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object('handle',h.handle,'name_at_hide',h.name_at_hide,
      'spot_name_at_hide',h.spot_name_at_hide,'hidden_at',h.hidden_at) order by h.hidden_at desc,h.handle),'[]'::jsonb),
    'limit',private.hidden_riders_limit())
  from private.hidden_riders h where h.user_id=p_user
$$;
revoke execute on function private.hidden_riders_of(uuid) from public,anon,authenticated,service_role;

create function api_v1.hidden_riders_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  return private.hidden_riders_of(private.account_deletion_caller());
end $$;
revoke execute on function api_v1.hidden_riders_list() from public;
grant execute on function api_v1.hidden_riders_list() to authenticated,service_role;

create function api_v1.hidden_riders_merge(items jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_user uuid:=private.account_deletion_caller();
  v_bad boolean;
begin
  if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)>private.hidden_riders_limit() then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"items"}';
  end if;
  select exists(select 1 from jsonb_array_elements(items) e where
      jsonb_typeof(e)<>'object'
      or exists(select 1 from jsonb_object_keys(e) k where k not in ('handle','name_at_hide','spot_name_at_hide','hidden_at'))
      or jsonb_typeof(e->'handle') is distinct from 'string' or e->>'handle' !~ '^[0-9a-f]{32}$'
      or (e ? 'name_at_hide' and (jsonb_typeof(e->'name_at_hide')<>'string' or char_length(e->>'name_at_hide')>40))
      or (e ? 'spot_name_at_hide' and (jsonb_typeof(e->'spot_name_at_hide')<>'string' or char_length(e->>'spot_name_at_hide')>100))
      or jsonb_typeof(e->'hidden_at') is distinct from 'string'
      or (e->>'hidden_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$')
    into v_bad;
  if v_bad then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"items"}';
  end if;
  if exists(select 1 from jsonb_array_elements(items) e
      where (e->>'hidden_at')::timestamptz>now()+interval '5 minutes'
         or (e->>'hidden_at')::timestamptz<'2026-01-01T00:00:00Z') then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"hidden_at"}';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('hidden-riders:'||v_user::text,0));
  -- 同一批裡重複的代號取最早的一筆。
  insert into private.hidden_riders as h(user_id,handle,name_at_hide,spot_name_at_hide,hidden_at)
  select distinct on (e->>'handle') v_user,e->>'handle',coalesce(e->>'name_at_hide',''),
    coalesce(e->>'spot_name_at_hide',''),(e->>'hidden_at')::timestamptz
  from jsonb_array_elements(items) e
  order by e->>'handle',(e->>'hidden_at')::timestamptz
  on conflict (user_id,handle) do update set
    name_at_hide=case when excluded.hidden_at<h.hidden_at then excluded.name_at_hide else h.name_at_hide end,
    spot_name_at_hide=case when excluded.hidden_at<h.hidden_at then excluded.spot_name_at_hide else h.spot_name_at_hide end,
    hidden_at=least(h.hidden_at,excluded.hidden_at);
  if (select count(*) from private.hidden_riders h where h.user_id=v_user)>private.hidden_riders_limit() then
    raise sqlstate 'PT400' using message='hidden_riders.too_many',
      detail=jsonb_build_object('limit',private.hidden_riders_limit())::text;
  end if;
  return private.hidden_riders_of(v_user);
end $$;
revoke execute on function api_v1.hidden_riders_merge(jsonb) from public;
grant execute on function api_v1.hidden_riders_merge(jsonb) to authenticated,service_role;

create function api_v1.hidden_riders_remove(handle text) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  v_user uuid:=private.account_deletion_caller();
begin
  if handle is null or handle !~ '^[0-9a-f]{32}$' then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"handle"}';
  end if;
  delete from private.hidden_riders h where h.user_id=v_user and h.handle=hidden_riders_remove.handle;
  return private.hidden_riders_of(v_user);
end $$;
revoke execute on function api_v1.hidden_riders_remove(text) from public;
grant execute on function api_v1.hidden_riders_remove(text) to authenticated,service_role;

-- ===== 2. 依 id 批次讀點位（收藏頁） =====
-- security invoker（同 spots_in_viewport）：社群點經 public_spots、官方點經
-- official_heavy_spots，都在呼叫者的 RLS 下讀；官方點的欄位與
-- official_viewport_spots_v3 相同。
create function api_v1.spots_by_ids(ids text[])
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_community uuid[];
  v_official uuid[];
begin
  if coalesce(cardinality(ids), 0) > 200 then
    raise sqlstate 'PT400' using message = 'request.too_many_ids', detail = '{"limit":200}';
  end if;
  select array_agg(distinct i::uuid) into v_community from unnest(ids) i
    where i ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  select array_agg(distinct substr(i, 10)::uuid) into v_official from unnest(ids) i
    where i ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  return jsonb_build_object('spots', (
    select coalesce(jsonb_agg(e order by k, id), '[]'::jsonb) from (
      select 0 as k, r.id, to_jsonb(r) || jsonb_build_object('contributor_handle', null, 'is_own', false) as e
      from (
        select 'official:'||o.id as id, 'official' as source, o.source_url, o.source_name, o.license_note, o.name, o.lat, o.lng,
          o.city, o.district, o.space_type, o.fee_note, o.note,
          o.heavy_allowed, o.scooter_allowed, 'confirmed' as status, o.updated_at,
          o.facility_type, o.parking_access, o.address, o.road_segment, o.scooter_total,
          o.entrance_note, o.parking_guide, o.special_rules, o.photo_urls, o.parking_zones, o.fee,
          ''::text as contributor_name, 'admin'::text as contributor_role, o.condition, o.zones_complete, o.closure,
          public.closure_state(o.closure) as closure_state, o.facility_types,
          o.parking_segments, o.scooter_not_stated, o.heavy_not_stated
        from public.official_heavy_spots o
        where o.id = any(coalesce(v_official, '{}')) and o.effective_date <= current_date
      ) r
      union all
      select 1, p.id::text, to_jsonb(p)
      from public.public_spots p where p.id = any(coalesce(v_community, '{}'))
    ) t
  ));
end;
$$;
revoke execute on function api_v1.spots_by_ids(text[]) from public;
grant execute on function api_v1.spots_by_ids(text[]) to anon, authenticated, service_role;
