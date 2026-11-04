-- #319：公開名稱只看使用者自己設定的 display_name（使用者決定 2026-11-04，
-- Google 和 Apple 一致：Google 姓名只是 App 的建議值，按「儲存」才公開）。
--
-- 1. contributor_display_name() 只讀 user_metadata.display_name，不再回退到
--    登入服務給的 full_name 或 name。清掉格式字元、控制字元與空白（含全形
--    空白 U+3000）後為空，就是沒有公開名稱；App 清空名稱時存空字串。
-- 2. 既有點位上的 contributor_name 一次重算（只改值不同的列，點位的更新時間
--    不變）。管理站帳號清單、編輯紀錄的名稱都呼叫同一支函式，一起改變。
-- 3. 代號（#280；使用者決定 PM_ANS_20261104_178＝B、_179＝B）：
--    a. 一次清除：從來沒有自己設定過 display_name（metadata 沒有這個字串鍵，
--       名稱只是後端從 Google 姓名帶出來）的帳號，刪除 private.contributor_handle_holders。
--       自己清空過（display_name 是空字串）或名稱被管理員清除（contributor_name_clears，
--       含檢舉結案「維持隱藏」）的帳號不刪：拿過代號就一直保留，不能靠改名或被清名
--       繞過別人的封鎖。只在這次遷移做。
--    b. 新的寫入路徑：auth.users 的 user_metadata 變成非空、不像 email 的 display_name 時（本人經
--       Supabase Auth 更新自己的資料；別人與用戶端都不能替他寫），不需要有看得到的
--       點就記入。代號由帳號以 HMAC 算出、密鑰不輪替，記回的是同一個代號，別人舊的
--       隱藏清單恢復有效。已經設定過名稱的帳號一併補記。

-- 202610250050_contributor_attribution.sql 的清理規則，只取 display_name。
create or replace function public.contributor_display_name(p_metadata jsonb)
returns text language sql immutable set search_path='' as $$
  select coalesce((
    select left(cleaned,40) from (
      -- Format characters (Unicode Cf: bidi controls, zero-width marks, tags)
      -- are removed so a name cannot be reordered, disguised or made invisible;
      -- whitespace, full-width included, collapses to one space.
      select btrim(regexp_replace(regexp_replace(p_metadata->>'display_name',
        '[\u00AD\u0600-\u0605\u061C\u06DD\u070F\u0890\u0891\u08E2\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF\uFFF9-\uFFFB\U000110BD\U000110CD\U00013430-\U0001343F\U0001BCA0-\U0001BCA3\U0001D173-\U0001D17A\U000E0001\U000E0020-\U000E007F]',
        '','g'),'[[:cntrl:][:space:]\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',' ','g')) as cleaned
      where jsonb_typeof(p_metadata->'display_name')='string'
    ) c where cleaned<>''
  ),'');
$$;
revoke execute on function public.contributor_display_name(jsonb) from public,anon,authenticated;

-- 重算：觸發器 community_spots_contributor 依新規則重算 contributor_name。
update public.community_spots s set contributor_name=''
  where s.contributor_name is distinct from public.spot_contributor_name(s.id,s.user_id,s.contributor_role);

-- a. 從來沒有自己設定過 display_name 的帳號：刪除代號紀錄。
delete from private.contributor_handle_holders h
  where not exists(select 1 from auth.users u where u.id=h.user_id
    and jsonb_typeof(u.raw_user_meta_data->'display_name')='string');

-- b. 本人設定非空 display_name：記入代號（不需要有看得到的點）。
create function public.contributor_handle_on_name() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- 像 email 的名稱不算公開名稱（#280）。
  if private.contributor_name_public(public.contributor_display_name(new.raw_user_meta_data))
     and new.deleted_at is null and not new.is_anonymous then
    perform private.contributor_handle_hold(new.id);
  end if;
  return null;
end $$;
revoke execute on function public.contributor_handle_on_name() from public,anon,authenticated,service_role;
create trigger contributor_handle_on_name after insert or update of raw_user_meta_data on auth.users
  for each row execute function public.contributor_handle_on_name();

-- 已經設定過名稱的帳號一併補記。
insert into private.contributor_handle_holders(user_id,handle)
select u.id,private.contributor_handle(u.id) from auth.users u
where private.contributor_name_public(public.contributor_display_name(u.raw_user_meta_data))
  and u.deleted_at is null and not u.is_anonymous
on conflict do nothing;
