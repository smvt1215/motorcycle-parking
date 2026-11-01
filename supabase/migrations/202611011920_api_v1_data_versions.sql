-- #195 P2: api_v1.data_versions() and a Broadcast on every bump.
--
-- An open App learns that spots or rules changed without polling the big
-- tables (#202). Until now the data_versions table reached it as Postgres
-- Changes (publication supabase_realtime); that stays for builds that use it.
-- New clients instead subscribe to the public Broadcast topic
-- `data_versions` (event `bump`, payload {key, version}) and read
-- api_v1.data_versions() for the authoritative numbers.
--
-- A public topic accepts messages from any client too, so a Broadcast is
-- only a hint: the App re-reads api_v1.data_versions() and acts on what that
-- returns. A forged hint costs one extra read, nothing more.
--
-- Sending never blocks the write that bumped the version: a Realtime
-- failure is swallowed, and clients still catch up on their next read
-- (start, foreground, reconnect).

create function api_v1.data_versions()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(key, version order by key), '{}'::jsonb)
  from public.data_versions;
$$;
revoke execute on function api_v1.data_versions() from public;
grant execute on function api_v1.data_versions() to anon, authenticated, service_role;

create function private.broadcast_data_version() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object('key', new.key, 'version', new.version),
      'bump',
      'data_versions',
      false
    );
  exception when others then
    -- Never fail the bump; clients catch up on their next read.
    null;
  end;
  return null;
end;
$$;
revoke execute on function private.broadcast_data_version() from public, anon, authenticated, service_role;

create trigger data_versions_broadcast
  after update of version on public.data_versions
  for each row
  when (new.version is distinct from old.version)
  execute function private.broadcast_data_version();
