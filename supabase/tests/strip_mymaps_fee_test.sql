-- 我的地圖費率片段清除（#275；202611020110_strip_mymaps_fee_fragments.sql）：
-- 清除後觸發器恢復、暫存表不留下；沒有這批資料的資料庫不推進 data_versions。
-- 逐列的新值由 tool/test_mymaps_strip_sql.py 與 staging 備份的本機演練驗證。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select is((select tgenabled::text from pg_trigger where tgname='community_spots_flags_from_entries'), 'O',
  'the community eligibility trigger is enabled again');
select is((select tgenabled::text from pg_trigger where tgname='official_heavy_spots_flags_from_entries'), 'O',
  'the official eligibility trigger is enabled again');
select is((select count(*)::int from pg_class where relname in ('strip_fee_c','strip_fee_o') and relpersistence='t'), 0,
  'the value tables are dropped');
select is((select count(*)::int from public.admin_audit_log where action in ('strip_copied_text','strip_copied_fee_text')), 0,
  'a database without the import records no strip');

select * from finish();
rollback;
