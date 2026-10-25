-- Public avatars use opaque, per-user object paths. No auth records are public.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('motopark-avatars','motopark-avatars',true,2097152,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create policy profile_avatars_read_own on storage.objects for select to authenticated
  using(bucket_id='motopark-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text)
    and coalesce((select auth.jwt())->>'is_anonymous','false')<>'true');
create policy profile_avatars_insert_own on storage.objects for insert to authenticated
  with check(bucket_id='motopark-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text)
    and array_length(storage.foldername(name),1)=1
    and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'
    and coalesce((select auth.jwt())->>'is_anonymous','false')<>'true');
create policy profile_avatars_delete_own on storage.objects for delete to authenticated
  using(bucket_id='motopark-avatars' and (storage.foldername(name))[1]=(select auth.uid()::text)
    and coalesce((select auth.jwt())->>'is_anonymous','false')<>'true');
