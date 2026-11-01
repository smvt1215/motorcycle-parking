-- 稽核紀錄中的我的地圖照抄文字遮蔽（#275；202611020120_mask_mymaps_audit_text.sql）：
-- 只有 admin_audit_mask_mymaps_text() 能把含來源署名的點位稽核改成遮蔽結果，
-- 其他欄位照留；其他修改仍然禁止。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note) values
  ('10000000-0000-4000-8000-000000000005','update_spot','community_spots','20000000-0000-4000-8000-0000000000b1',
   '{"note":"猴子很多東西要收好","entrance_note":"","fee_note":"免費；需按鈴","license_note":"整理自 Alan大重停車記事（Google 我的地圖）","status":"pending"}',
   '{"note":"猴子很多東西要收好","entrance_note":"後牌辨析","fee_note":"免費","license_note":"整理自 Alan大重停車記事（Google 我的地圖）","status":"confirmed"}',
   'x'),
  ('10000000-0000-4000-8000-000000000005','update_spot','community_spots','20000000-0000-4000-8000-0000000000b2',
   '{"note":"車友回報"}','{"note":"管理員改寫"}','y'),
  ('10000000-0000-4000-8000-000000000005','update_spot','admin_users','20000000-0000-4000-8000-0000000000b3',
   '{"note":"Alan大重停車記事"}',null,'z');

select throws_ok($$update public.admin_audit_log set note='' where target_id='20000000-0000-4000-8000-0000000000b1'$$,
  '42501', null, 'entries still cannot be changed directly');
select set_config('app.audit_mask_mymaps','on',true);
select throws_ok($$update public.admin_audit_log set before=private.audit_mask_mymaps(before),after=private.audit_mask_mymaps(after),note=''
  where target_id='20000000-0000-4000-8000-0000000000b1'$$, '42501', null, 'the mask allows no other change');
select throws_ok($$update public.admin_audit_log set after='{"note":"（已遮蔽：我的地圖照抄文字，#275）"}'
  where target_id='20000000-0000-4000-8000-0000000000b2'$$, '42501', null, 'an entry without the source credit stays');
select set_config('app.audit_mask_mymaps','',true);

select is(public.admin_audit_mask_mymaps_text(), 1, 'only the spot entry with the source credit is masked');
select is((select before from public.admin_audit_log where target_id='20000000-0000-4000-8000-0000000000b1'),
  '{"note":"（已遮蔽：我的地圖照抄文字，#275）","entrance_note":"","fee_note":"免費；需按鈴","license_note":"（已遮蔽：我的地圖照抄文字，#275）","status":"pending"}'::jsonb,
  'text keys are masked, empty ones and the other keys stay');
select is((select after->>'entrance_note' from public.admin_audit_log where target_id='20000000-0000-4000-8000-0000000000b1'),
  '（已遮蔽：我的地圖照抄文字，#275）', 'after is masked too');
select is((select note from public.admin_audit_log where target_id='20000000-0000-4000-8000-0000000000b1'), 'x', 'the entry note stays');
select is((select after->>'note' from public.admin_audit_log where target_id='20000000-0000-4000-8000-0000000000b2'), '管理員改寫',
  'an entry without the source credit is not touched');
select is((select before->>'note' from public.admin_audit_log where target_id='20000000-0000-4000-8000-0000000000b3'), 'Alan大重停車記事',
  'entries of other tables are not touched');
select is((select (after->>'entries')::int from public.admin_audit_log where action='mask_mymaps_audit_text' order by id desc limit 1), 1,
  'the mask is audited');
select is(public.admin_audit_mask_mymaps_text(), 0, 'a second run finds nothing');
select throws_ok($$delete from public.admin_audit_log where target_id='20000000-0000-4000-8000-0000000000b1'$$,
  '42501', null, 'masked entries still cannot be deleted');
select ok(not has_function_privilege('service_role','public.admin_audit_mask_mymaps_text()','execute'),
  'only the database owner runs the mask');

select * from finish();
rollback;
