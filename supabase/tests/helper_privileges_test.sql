-- 內部 helper 的 EXECUTE 權限（#195 P0；202611010100_revoke_helper_execute.sql）：
-- anon／authenticated 不能直接呼叫內部 helper，但 App 用到的 API 與它們
-- 依賴的鏈仍可執行，CHECK 約束也照常在 postgres 寫入時生效。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create temporary table revoked(sig text) on commit drop;
insert into revoked values
  ('admin_audit_log_immutable()'), ('assign_entry_ids()'), ('city_rules_history_immutable()'),
  ('community_spots_confirmed_at()'), ('moderation_base_version()'), ('moderation_close_legacy()'),
  ('spot_fee_plans_sync()'), ('spot_fee_source_text()'), ('sync_facility_types()'),
  ('availability_classify(integer,integer)'), ('availability_int(jsonb)'), ('rider_min_credibility()'),
  ('sighting_official_level(integer,integer)'),
  ('condition_bay_kind(jsonb)'), ('contract_date(jsonb)'), ('contract_entry_ids(jsonb)'),
  ('contract_fee_fields(jsonb,jsonb,text)'), ('contract_fee_rate(jsonb,text,boolean)'), ('contract_https(jsonb)'),
  ('contract_slot_keys(jsonb,jsonb)'), ('contract_slot_times(jsonb)'), ('contract_str_in(jsonb,jsonb)'),
  ('contract_subset(jsonb,jsonb)'), ('contract_text(jsonb,integer)'), ('contract_whole(jsonb,numeric,numeric)'),
  ('facility_types_ordered(text[])'), ('valid_closure(jsonb)'), ('valid_condition(jsonb,boolean)'),
  ('valid_facility_types(text[])'), ('valid_segments(jsonb)'), ('valid_spot_condition(text,text,jsonb,jsonb,boolean)'),
  ('valid_zones(jsonb)'), ('zone_condition_consistent(jsonb)'),
  ('entries_have_ids(jsonb)'), ('entries_patch(jsonb,jsonb)'), ('entries_patch_conflict(jsonb,jsonb,jsonb)'),
  ('entries_with_ids(jsonb,jsonb,text[])'),
  ('fee_note_max_length()'), ('fee_note_of(jsonb)'), ('fee_plan_name(jsonb)'), ('fee_plans_absorb(jsonb,jsonb)'),
  ('fee_text_day_mask(jsonb)'), ('fee_text_days(integer)'), ('fee_text_every(jsonb)'), ('fee_text_money(jsonb,integer)'),
  ('fee_text_rate(jsonb,integer)'), ('fee_text_reset(text)'), ('fee_text_span(jsonb)'), ('fee_whole(jsonb,integer,integer)'),
  ('valid_fee(jsonb)'), ('valid_fee_plans(jsonb,text,jsonb,jsonb)'), ('valid_fee_rate(jsonb,boolean)'),
  ('valid_zone_fees(jsonb)'), ('zones_without_plans(jsonb)');

-- Every revoked helper exists (a renamed function would silently keep its grant).
select ok(to_regprocedure('public.'||sig) is not null, sig||' exists') from revoked;

select ok(not has_function_privilege(role, 'public.'||sig, 'execute'), role||' cannot execute '||sig)
from revoked cross join (values ('anon'), ('authenticated')) r(role);

-- The API the App calls, and the helpers anon reaches through it, stay open:
-- viewport_spots and its v2 run legacy_projection's chain as the caller,
-- public_spots and official_viewport_spots_v3 call closure_state, and the
-- city_rules view calls city_rules_v2.
select ok(has_function_privilege('anon', 'public.'||sig, 'execute'), 'anon can execute '||sig)
from (values
  ('viewport_spots(double precision,double precision,double precision,double precision)'),
  ('viewport_spots_v2(double precision,double precision,double precision,double precision)'),
  ('viewport_spots_v3(double precision,double precision,double precision,double precision)'),
  ('official_viewport_spots(double precision,double precision,double precision,double precision)'),
  ('official_viewport_spots_v2(double precision,double precision,double precision,double precision)'),
  ('official_viewport_spots_v3(double precision,double precision,double precision,double precision)'),
  ('city_rules_v2()'), ('holiday_calendar(integer,integer)'), ('spot_history(text)'),
  ('viewport_availability(text[])'), ('spot_sightings(text[])'),
  ('legacy_projection(jsonb)'), ('condition_legacy_safe_spot(boolean,jsonb,jsonb)'), ('zone_legacy_safe(jsonb)'),
  ('condition_legacy_safe(jsonb,boolean)'), ('condition_legacy_access(jsonb)'), ('condition_off_street(text,text)'),
  ('condition_space_type(jsonb,boolean)'), ('parking_contract()'),
  ('closure_state(jsonb)'), ('closure_ends_on(jsonb)'), ('closure_date(text)')
) api(sig);

-- A spot the viewports return, so their helper chains actually run for anon.
-- Owned by a seeded rider (user_id references auth.users).
insert into community_spots(user_id, name, lat, lng, city, district, space_type, status, scooter_allowed, heavy_allowed)
select user_id, '權限測試機車格', 25.0418, 121.5437, '臺北市', '大安區', 'freeMotorcycle', 'confirmed', true, false
from community_spots limit 1;

set local role anon;
select lives_ok($$select count(*) from public.viewport_spots(25.0, 121.5, 25.1, 121.6)$$, 'anon reads viewport_spots (legacy_projection chain)');
select lives_ok($$select count(*) from public.viewport_spots_v2(25.0, 121.5, 25.1, 121.6)$$, 'anon reads viewport_spots_v2');
select lives_ok($$select count(*) from public.viewport_spots_v3(25.0, 121.5, 25.1, 121.6)$$, 'anon reads viewport_spots_v3');
select lives_ok($$select count(*) from public.official_viewport_spots(25.0, 121.5, 25.1, 121.6)$$, 'anon reads official_viewport_spots');
select lives_ok($$select count(*) from public.official_viewport_spots_v2(25.0, 121.5, 25.1, 121.6)$$, 'anon reads official_viewport_spots_v2');
select lives_ok($$select count(*) from public.official_viewport_spots_v3(25.0, 121.5, 25.1, 121.6)$$, 'anon reads official_viewport_spots_v3 (closure_state)');
select lives_ok($$select count(*) from public.city_rules$$, 'anon reads the city_rules view');
select ok((select count(*) from public.viewport_spots_v2(25.0, 121.5, 25.1, 121.6)) >= 1,
  'the viewport returns rows, so its helper chain ran for anon');
select throws_ok($$select public.valid_fee('{}'::jsonb)$$, '42501', null, 'anon calling a revoked helper is refused');
reset role;

-- Constraints that use revoked helpers still check writes made by the owner.
select throws_ok(
  $$update community_spots set fee = '{"scooter":{"mode":"bogus"}}'::jsonb where name = '權限測試機車格'$$,
  '23514', null, 'valid_fee still guards writes');

select * from finish();
rollback;
