-- 公開名稱只看 display_name（#319；202611041000_display_name_only.sql）。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

select is(contributor_display_name('{"display_name":"阿明"}'),'阿明','a display_name is the public name');
select is(contributor_display_name('{"display_name":"  阿明  ","full_name":"王大明"}'),'阿明','trimmed, and it wins over full_name');
select is(contributor_display_name('{"display_name":""}'),'','an empty string is no name');
select is(contributor_display_name('{"display_name":"   "}'),'','spaces only are no name');
select is(contributor_display_name(jsonb_build_object('display_name',E'\u3000\u3000')),'','full-width spaces only are no name');
select is(contributor_display_name(jsonb_build_object('display_name',E'\u3000阿\u3000明\u3000')),'阿 明','full-width spaces are trimmed and collapse');
select is(contributor_display_name(jsonb_build_object('display_name',E'\n\t\u00A0\u200B')),'','control, no-break and zero-width only are no name');
select is(contributor_display_name('{"full_name":"王大明"}'),'','full_name alone is not a public name');
select is(contributor_display_name('{"name":"王大明"}'),'','name alone is not a public name');
select is(contributor_display_name('{"display_name":"","full_name":"王大明","name":"王大明"}'),'',
  'a cleared display_name never falls back to the sign-in name');
select is(contributor_display_name('{"display_name":null,"full_name":"王大明"}'),'','a null display_name neither');
select is(contributor_display_name('{"display_name":42}'),'','a display_name that is not text is no name');
select is(contributor_display_name('{}'),'','no metadata, no name');
select is(contributor_display_name(null),'','null metadata, no name');
select is(char_length(contributor_display_name(jsonb_build_object('display_name',repeat('車',60)))),40,'bounded to 40 characters');

-- 點位跟著帳號：只有 full_name 的帳號沒有名稱，設了 display_name 才有，清空又沒有。
update auth.users set raw_user_meta_data='{"full_name":"王大明","name":"王大明"}' where id='10000000-0000-4000-8000-000000000006';
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('7e000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000006','名稱測試點',23.301,120.301,'雲林縣','freeMotorcycle',true,false,'pending');
select is((select contributor_name from community_spots where id='7e000000-0000-4000-8000-000000000001'),'','a Google name alone is not shown');
select ok(not exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000006'),
  'nor does it give a handle');
update auth.users set raw_user_meta_data='{"full_name":"王大明","display_name":"小明"}' where id='10000000-0000-4000-8000-000000000006';
select is((select contributor_name from community_spots where id='7e000000-0000-4000-8000-000000000001'),'小明','saving a name shows it');
create temporary table h as select handle from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000006';
update auth.users set raw_user_meta_data='{"full_name":"王大明","display_name":""}' where id='10000000-0000-4000-8000-000000000006';
select is((select contributor_name from community_spots where id='7e000000-0000-4000-8000-000000000001'),'','clearing it hides it again');
select is(public.spot_contributor_handle('7e000000-0000-4000-8000-000000000001'),(select handle from h),
  'and the handle stays (#280)');

-- 重算：遷移前用 full_name 回退寫下的快照，改回新規則（點位更新時間不變）。
alter table community_spots disable trigger community_spots_contributor;
update community_spots set contributor_name='王大明',updated_at='2026-01-01T00:00:00Z' where id='7e000000-0000-4000-8000-000000000001';
alter table community_spots enable trigger community_spots_contributor;
create temporary table before_recompute as select updated_at from community_spots where id='7e000000-0000-4000-8000-000000000001';
update public.community_spots s set contributor_name=''
  where s.contributor_name is distinct from public.spot_contributor_name(s.id,s.user_id,s.contributor_role);
select is((select contributor_name from community_spots where id='7e000000-0000-4000-8000-000000000001'),'','the recompute clears a fallback name');
select is((select updated_at from community_spots where id='7e000000-0000-4000-8000-000000000001'),(select updated_at from before_recompute),
  'without touching the spot''s freshness');
select is((select count(*)::int from community_spots s
  where s.contributor_name is distinct from public.spot_contributor_name(s.id,s.user_id,s.contributor_role)),0,'every snapshot matches the rule');
select is((select handle from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000006'),(select handle from h),
  'the recompute leaves handles alone');

-- 管理站帳號清單（admin_users、admin_user_detail）呼叫的就是這支函式。
select is((select contributor_display_name(u.raw_user_meta_data) from auth.users u where u.id='10000000-0000-4000-8000-000000000006'),'',
  'the function the admin user list calls gives no name either');

select * from finish();
rollback;
