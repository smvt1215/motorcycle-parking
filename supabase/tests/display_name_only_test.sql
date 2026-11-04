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

-- ===== 只靠回退名稱拿到的代號（PM_ANS_20261104_178＝B） =====
-- 遷移前：帳號 7 只有 Google 姓名，點位上曾以回退名稱公開，因而有代號。
update auth.users set raw_user_meta_data='{"full_name":"陳回退"}' where id='10000000-0000-4000-8000-000000000007';
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('7e000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000007','回退點',23.302,120.302,'雲林縣','freeMotorcycle',true,false,'pending');
insert into private.contributor_handle_holders(user_id,handle)
values('10000000-0000-4000-8000-000000000007',private.contributor_handle('10000000-0000-4000-8000-000000000007'))
on conflict do nothing;
create temporary table fallback as select private.contributor_handle('10000000-0000-4000-8000-000000000007') as handle;
select is(public.spot_contributor_handle('7e000000-0000-4000-8000-000000000002'),(select handle from fallback),'(before) the fallback name gave a handle');
-- 別人隱藏了他。
insert into private.hidden_riders(user_id,handle,name_at_hide,spot_name_at_hide,hidden_at)
values('10000000-0000-4000-8000-000000000002',(select handle from fallback),'陳回退','回退點',now());
-- 帳號 6 目前有自己設定的名稱。
update auth.users set raw_user_meta_data='{"display_name":"小明"}' where id='10000000-0000-4000-8000-000000000006';
-- 帳號 3 自己清空過名稱（display_name 是空字串），帳號 1 的名稱被管理員清除；兩者都拿過代號。
update auth.users set raw_user_meta_data='{"full_name":"林自清","display_name":""}' where id='10000000-0000-4000-8000-000000000003';
update auth.users set raw_user_meta_data='{"display_name":"被清名"}' where id='10000000-0000-4000-8000-000000000001';
insert into private.contributor_handle_holders(user_id,handle)
select u,private.contributor_handle(u) from unnest(array['10000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001']::uuid[]) u
on conflict do nothing;
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('7e000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001','被清名的點',23.303,120.303,'雲林縣','freeMotorcycle',true,false,'pending');
insert into contributor_name_clears(spot_id,cleared_by) values('7e000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000005');
update community_spots set note='清除後' where id='7e000000-0000-4000-8000-000000000003';
select is((select contributor_name from community_spots where id='7e000000-0000-4000-8000-000000000003'),'','(setup) an admin cleared the name');
-- 帳號 2 只有 Google 姓名、靠回退名稱拿過代號，之後名稱被管理員清除。
update auth.users set raw_user_meta_data='{"full_name":"張被清"}' where id='10000000-0000-4000-8000-000000000002';
insert into private.contributor_handle_holders(user_id,handle)
values('10000000-0000-4000-8000-000000000002',private.contributor_handle('10000000-0000-4000-8000-000000000002')) on conflict do nothing;
insert into community_spots(id,user_id,name,lat,lng,city,space_type,scooter_allowed,heavy_allowed,status)
values('7e000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000002','回退又被清名',23.304,120.304,'雲林縣','freeMotorcycle',true,false,'pending');
insert into contributor_name_clears(spot_id,cleared_by) values('7e000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000005');
-- 遷移的刪除：只刪從來沒有自己設定過 display_name、名稱也沒被管理員清除過的帳號。
delete from private.contributor_handle_holders h
  where not exists(select 1 from auth.users u where u.id=h.user_id
      and jsonb_typeof(u.raw_user_meta_data->'display_name')='string')
    and not exists(select 1 from public.community_spots s join public.contributor_name_clears c on c.spot_id=s.id
      where s.user_id=h.user_id);
select ok(exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000002'),
  'a Google-name-only rider whose name an admin cleared keeps the handle');
select ok(exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000003'),
  'a rider who cleared their own name keeps the handle');
select is(public.spot_contributor_handle('7e000000-0000-4000-8000-000000000003'),private.contributor_handle('10000000-0000-4000-8000-000000000001'),
  'a rider whose name an admin cleared keeps the handle');
select is(public.spot_contributor_handle('7e000000-0000-4000-8000-000000000002'),null,'a handle from a fallback name is removed');
select ok(exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000006'),
  'a handle from a name the rider set stays');
update auth.users set raw_user_meta_data='{"full_name":"王大明","display_name":""}' where id='10000000-0000-4000-8000-000000000006';
select ok(not exists(select 1 from private.hidden_riders r join public.public_spots p on p.contributor_handle=r.handle
    where r.user_id='10000000-0000-4000-8000-000000000002' and p.id='7e000000-0000-4000-8000-000000000002'),
  'so the other rider''s hide no longer matches his spot');
-- 本人自己設定名稱：不需要有看得到的點就拿回同一個代號。
update community_spots set status='hidden' where id='7e000000-0000-4000-8000-000000000002';
update auth.users set raw_user_meta_data='{"full_name":"陳回退","display_name":"阿陳"}' where id='10000000-0000-4000-8000-000000000007';
select is((select handle from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000007'),(select handle from fallback),
  'setting a name records the same handle, with no visible spot');
update community_spots set status='pending' where id='7e000000-0000-4000-8000-000000000002';
select is(public.spot_contributor_handle('7e000000-0000-4000-8000-000000000002'),(select handle from fallback),
  'setting a name gives back the same handle');
select ok(exists(select 1 from private.hidden_riders r join public.public_spots p on p.contributor_handle=r.handle
    where r.user_id='10000000-0000-4000-8000-000000000002' and p.id='7e000000-0000-4000-8000-000000000002'),
  'and the old hide matches again');
-- 之後再清空：照 #280 保留（只有遷移那次會刪）。
update auth.users set raw_user_meta_data='{"full_name":"陳回退","display_name":""}' where id='10000000-0000-4000-8000-000000000007';
select is(public.spot_contributor_handle('7e000000-0000-4000-8000-000000000002'),(select handle from fallback),
  'clearing it later keeps the handle');

-- 名稱被管理員清除的帳號，本人再設定名稱：仍是同一個代號。
update auth.users set raw_user_meta_data='{"display_name":"新名字"}' where id='10000000-0000-4000-8000-000000000001';
select is((select handle from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000001'),
  private.contributor_handle('10000000-0000-4000-8000-000000000001'),'renaming after an admin clear keeps the same handle');
-- 匿名登入的帳號不記。
update auth.users set raw_user_meta_data='{"display_name":"匿名"}' where id='10000000-0000-4000-8000-000000000004';
select ok(not exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000004'),
  'an anonymous sign-in gets no handle');
-- 像 email 的名稱不記（#280）。
update auth.users set raw_user_meta_data='{"display_name":"a@b.test"}' where id='10000000-0000-4000-8000-000000000006';
delete from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000006';
update auth.users set raw_user_meta_data='{"display_name":"c@d.test"}' where id='10000000-0000-4000-8000-000000000006';
select ok(not exists(select 1 from private.contributor_handle_holders where user_id='10000000-0000-4000-8000-000000000006'),
  'an email-like name gives no handle');
update auth.users set raw_user_meta_data='{"full_name":"王大明","display_name":""}' where id='10000000-0000-4000-8000-000000000006';
-- 新帳號註冊時就帶 display_name 也記入；只有 Google 姓名的不記。
select ok(exists(select 1 from pg_trigger where tgname='contributor_handle_on_name' and tgrelid='auth.users'::regclass),
  'the trigger watches account metadata');

-- 管理站帳號清單（admin_users、admin_user_detail）呼叫的就是這支函式。
select is((select contributor_display_name(u.raw_user_meta_data) from auth.users u where u.id='10000000-0000-4000-8000-000000000006'),'',
  'the function the admin user list calls gives no name either');

select * from finish();
rollback;
