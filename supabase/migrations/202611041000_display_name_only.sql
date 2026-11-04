-- #319：公開名稱只看使用者自己設定的 display_name（使用者決定 2026-11-04，
-- Google 和 Apple 一致：Google 姓名只是 App 的建議值，按「儲存」才公開）。
--
-- 1. contributor_display_name() 只讀 user_metadata.display_name，不再回退到
--    登入服務給的 full_name 或 name。清掉格式字元、控制字元與空白（含全形
--    空白 U+3000）後為空，就是沒有公開名稱；App 清空名稱時存空字串。
-- 2. 既有點位上的 contributor_name 一次重算（只改值不同的列，點位的更新時間
--    不變）。管理站帳號清單、編輯紀錄的名稱都呼叫同一支函式，一起改變。
-- 3. 代號（#280）：private.contributor_handle_holders 不動。過去只靠 full_name
--    回退而「公開」過名稱的帳號照樣保留代號；這是待決的取捨（見 PR 說明）。

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
