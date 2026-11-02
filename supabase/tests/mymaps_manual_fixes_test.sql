-- 我的地圖匯入點的人工修正（#275；202611020130_mymaps_manual_fixes.sql）：
-- 觸發器恢復、暫存表不留下；沒有這批資料的資料庫不寫任何稽核。
-- 逐列的新值由 tool/test_mymaps_strip_sql.py 與 staging 備份的本機演練驗證。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select is((select tgenabled::text from pg_trigger where tgname='community_spots_flags_from_entries'), 'O',
  'the community eligibility trigger is enabled again');
select is((select tgenabled::text from pg_trigger where tgname='official_heavy_spots_flags_from_entries'), 'O',
  'the official eligibility trigger is enabled again');
select is((select count(*)::int from pg_class where relname='manual_fix' and relpersistence='t'), 0, 'the value table is dropped');
select is((select count(*)::int from public.admin_audit_log where action in ('manual_fix_text','manual_fix_text_summary')), 0,
  'a database without the import records no fix');

select * from finish();
rollback;
