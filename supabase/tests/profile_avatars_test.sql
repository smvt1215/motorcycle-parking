begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();
-- Storage API deletes set this flag; RLS still decides which rows are visible.
select set_config('storage.allow_delete_query','true',true);

select is((select file_size_limit from storage.buckets where id='motopark-avatars'),2097152::bigint,'avatar uploads limited to 2 MB');
select is((select public from storage.buckets where id='motopark-avatars'),true,'avatar public URLs can be read');
select is((select allowed_mime_types from storage.buckets where id='motopark-avatars'),array['image/jpeg','image/png','image/webp'],'only supported image MIME types');

select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","is_anonymous":false}',true);
set local role authenticated;
select lives_ok($$insert into storage.objects(bucket_id,name) values('motopark-avatars','10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000001.png')$$,'rider can insert their own avatar');
select throws_ok($$insert into storage.objects(bucket_id,name) values('motopark-avatars','10000000-0000-4000-8000-000000000002/20000000-0000-4000-8000-000000000002.png')$$,'42501',null,'rider cannot insert another user avatar');
select throws_ok($$insert into storage.objects(bucket_id,name) values('motopark-avatars','10000000-0000-4000-8000-000000000001/nested/20000000-0000-4000-8000-000000000002.png')$$,'42501',null,'avatar objects use one user directory');
select throws_ok($$insert into storage.objects(bucket_id,name) values('motopark-avatars','10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000002.html')$$,'42501',null,'other file extensions are refused');
reset role;

insert into storage.objects(bucket_id,name) values('motopark-avatars','10000000-0000-4000-8000-000000000002/20000000-0000-4000-8000-000000000002.png');
set local role authenticated;
select is((select count(*)::integer from storage.objects where bucket_id='motopark-avatars'),1,'listing only returns the rider own avatar');
delete from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000002/%';
reset role;
select is((select count(*)::integer from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000002/%'),1,'another user avatar is not deleted');
set local role authenticated;
delete from storage.objects where bucket_id='motopark-avatars' and name like '10000000-0000-4000-8000-000000000001/%';
select is((select count(*)::integer from storage.objects where bucket_id='motopark-avatars'),0,'rider can delete their own avatar');
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","is_anonymous":true}',true);
select throws_ok($$insert into storage.objects(bucket_id,name) values('motopark-avatars','10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000003.png')$$,'42501',null,'anonymous accounts cannot upload profile avatars');
reset role;

select * from finish();
rollback;
