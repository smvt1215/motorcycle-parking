-- #280 第 1 層：社群點的公開代號 contributor_handle 與 is_own（使用者決定
-- PM_ASSIGN_20261102_161；提案 t280-proposal.md 第 1 節）。
--
-- 1. 「公開過名稱」：帳號在一個車友新增（contributor_role='rider'）、地圖上
--    看得到（status<>'hidden'、deleted_at is null）的點上，伺服器算出的
--    contributor_name 非空且不含 @（和 App contributorSummary() 判斷「像
--    email」一致）。發生過一次就記在 private.contributor_handle_holders，
--    之後改名、名稱空白或像 email、被管理員清除都照樣有代號，直到刪除帳號
--    （on delete cascade）。只記「有沒有」，不記名稱。
-- 2. 代號＝HMAC-SHA256(uid, 伺服器密鑰) 的前 128 bit（32 個小寫 hex），密鑰
--    在 private.contributor_handle_key，不輪替。讀取時才算、不快取在點位
--    上：點位整列會被快照進 moderation_queue.base_spot、admin_audit_log 等
--    處，快取欄位會讓代號在帳號刪除後還留著、可以串連。帳號一刪（user_id
--    set null、holders cascade）就算不出來。從不回傳 uid。
-- 3. is_own：已登入且投稿者是自己；未登入一律 false。
-- 4. public_spots 最後加 contributor_handle、is_own 兩欄，viewport_spots_v3
--    （App 目前讀的）與 api_v1.spots_in_viewport 一起有；官方點補 null／false。
--    view 是 security invoker，anon 對 user_id 沒有欄位權限，所以由兩支
--    security definer 函式計算。這兩支是 helper revoke 規則的例外：invoker
--    view 呼叫它們需要 anon／authenticated 的 EXECUTE。函式自己套用和
--    public_spots RLS 相同的可見條件，看不到的點回 null／false，直接以 RPC
--    呼叫也拿不到 view 以外的資訊。

-- ===== 1. 密鑰與「公開過名稱」 =====
create table private.contributor_handle_key (
  id boolean primary key default true check (id),
  key bytea not null check (octet_length(key)>=32)
);
insert into private.contributor_handle_key(key) values(extensions.gen_random_bytes(32));
revoke all on private.contributor_handle_key from public,anon,authenticated,service_role;

create table private.contributor_handle_holders (
  user_id uuid primary key references auth.users(id) on delete cascade,
  first_public_at timestamptz not null default now()
);
revoke all on private.contributor_handle_holders from public,anon,authenticated,service_role;
comment on table private.contributor_handle_holders is
  '公開過名稱的帳號（#280）：有這列才有 contributor_handle；帳號刪除時一併刪除。';

-- 名稱算不算公開：非空、不含 @。
create function private.contributor_name_public(p_name text) returns boolean
language sql immutable security definer set search_path='' as $$
  select coalesce(btrim(p_name),'')<>'' and position('@' in p_name)=0
$$;
revoke execute on function private.contributor_name_public(text) from public,anon,authenticated,service_role;

create function private.contributor_handle(p_user uuid) returns text
language sql stable security definer set search_path='' as $$
  select encode(substring(extensions.hmac(convert_to(p_user::text,'UTF8'),k.key,'sha256') from 1 for 16),'hex')
  from private.contributor_handle_key k
  where p_user is not null
$$;
revoke execute on function private.contributor_handle(uuid) from public,anon,authenticated,service_role;

-- ===== 2. 寫入路徑：既有的 community_spots_contributor 觸發器 =====
-- 所有寫入（新增、改名同步、管理員復原、匯入）都經過它；其餘與
-- 202610250050_contributor_attribution.sql 相同。
create or replace function public.community_spot_contributor() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='INSERT' then
    new.contributor_role:=public.spot_contributor_role(new.user_id,new.source);
  else
    new.contributor_role:=old.contributor_role;
  end if;
  new.contributor_name:=public.spot_contributor_name(new.id,new.user_id,new.contributor_role);
  if new.user_id is not null and new.contributor_role='rider' and new.status<>'hidden'
     and new.deleted_at is null and private.contributor_name_public(new.contributor_name) then
    insert into private.contributor_handle_holders(user_id) values(new.user_id) on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke execute on function public.community_spot_contributor() from public,anon,authenticated,service_role;

-- ===== 3. 回填 =====
-- 目前公開的名稱。
insert into private.contributor_handle_holders(user_id)
select distinct s.user_id from public.community_spots s
where s.user_id is not null and s.contributor_role='rider' and s.status<>'hidden'
  and s.deleted_at is null and private.contributor_name_public(s.contributor_name)
on conflict do nothing;
-- 以前公開過、後來被管理員清除或改掉的名稱：稽核紀錄與回報快照裡的前後值。
-- 只會多給代號，不會少給（拿過就一直保留）。
insert into private.contributor_handle_holders(user_id)
select distinct s.user_id
from public.community_spots s
join (
  select a.target_id as spot_id, v.name
  from public.admin_audit_log a
  cross join lateral (values (a.before->>'contributor_name'),(a.after->>'contributor_name')) v(name)
  where a.target_table='community_spots'
  union all
  select q.source_id, q.base_spot->>'contributor_name' from public.moderation_queue q
  where q.base_spot is not null
) past on past.spot_id=s.id::text
where s.user_id is not null and s.contributor_role='rider'
  and private.contributor_name_public(past.name)
  and past.name<>private.audit_redacted_name()
on conflict do nothing;

-- ===== 4. 給 public_spots 的兩支函式（例外：anon／authenticated 可執行） =====
create function public.spot_contributor_handle(p_spot uuid) returns text
language sql stable security definer set search_path='' as $$
  select private.contributor_handle(s.user_id)
  from public.community_spots s
  join private.contributor_handle_holders h on h.user_id=s.user_id
  where s.id=p_spot and s.contributor_role='rider' and s.status<>'hidden' and s.deleted_at is null
$$;
revoke execute on function public.spot_contributor_handle(uuid) from public;
grant execute on function public.spot_contributor_handle(uuid) to anon,authenticated,service_role;

create function public.spot_is_own(p_spot uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select (select auth.uid()) is not null and exists(
    select 1 from public.community_spots s
    where s.id=p_spot and s.user_id=(select auth.uid()) and s.status<>'hidden' and s.deleted_at is null)
$$;
revoke execute on function public.spot_is_own(uuid) from public;
grant execute on function public.spot_is_own(uuid) to anon,authenticated,service_role;

-- 202610310300_soft_delete_spots.sql 的 view，最後加兩欄。
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role,scooter_verified_at,heavy_verified_at,
    condition,zones_complete,closure,public.closure_state(closure) as closure_state,facility_types,parking_segments,
    scooter_not_stated,heavy_not_stated,
    public.spot_contributor_handle(id) as contributor_handle,
    public.spot_is_own(id) as is_own
  from public.community_spots
  where deleted_at is null;

-- ===== 5. api_v1.spots_in_viewport：官方點補 null／false =====
-- 其餘與 202611011820_api_v1_spots_in_viewport.sql 相同。
create or replace function api_v1.spots_in_viewport(
  south double precision,
  west double precision,
  north double precision,
  east double precision
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_community jsonb;
  v_official jsonb := '[]'::jsonb;
  v_official_failed boolean := false;
  v_truncated boolean := false;
begin
  select coalesce(jsonb_agg(to_jsonb(s) order by s.id), '[]'::jsonb)
  into v_community
  from public.viewport_spots_v3(south, west, north, east) s;
  begin
    select coalesce(jsonb_agg(to_jsonb(o)
        || jsonb_build_object('contributor_handle', null, 'is_own', false) order by o.id), '[]'::jsonb)
    into v_official
    from public.official_viewport_spots_v3(south, west, north, east) o;
  exception
    -- A bad box is the caller's error, not a missing layer.
    when invalid_parameter_value then raise;
    when others then
      v_official := '[]'::jsonb;
      v_official_failed := true;
  end;
  -- Each layer returns up to 501 rows so a full one reads as truncated.
  if jsonb_array_length(v_community) > 500 or jsonb_array_length(v_official) > 500 then
    v_truncated := true;
  end if;
  return jsonb_build_object(
    'spots', (
      select coalesce(jsonb_agg(e), '[]'::jsonb) from (
        select e from jsonb_array_elements(v_official) with ordinality t(e, n) where n <= 500
        union all
        select e from jsonb_array_elements(v_community) with ordinality t(e, n) where n <= 500
      ) merged
    ),
    'truncated', v_truncated,
    'official_unavailable', v_official_failed
  );
end;
$$;
revoke execute on function api_v1.spots_in_viewport(double precision, double precision, double precision, double precision) from public;
grant execute on function api_v1.spots_in_viewport(double precision, double precision, double precision, double precision)
  to anon, authenticated, service_role;
