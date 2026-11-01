-- #195 P2: the minimum App version moves out of client_config()'s code into
-- a guarded setting (user decisions, PM_ANS_20261101_77 and _87).
--
-- An App below min_supported_app_version is blocked entirely, so a wrong or
-- missing value would lock every rider out. Hence:
--   * fail open: no row, a malformed value or any read error serves the
--     non-blocking FLOOR (0.1.0, what the code served before);
--   * one write path, admin_v1.set_min_supported_app_version(), audited in
--     admin_audit_log: an admin may raise or lower; CD (service_role) may
--     only raise, and names its run in the reason;
--   * nobody writes the table directly (no grants; RLS on).

create table private.app_version_policy (
  -- One row: the minimum version clients must run.
  id boolean primary key default true check (id),
  min_supported_app_version text not null
    check (min_supported_app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  updated_at timestamptz not null default now()
);
alter table private.app_version_policy enable row level security;
revoke all on private.app_version_policy from public, anon, authenticated, service_role;
insert into private.app_version_policy(min_supported_app_version) values ('0.1.0');

-- x.y.z as an int[] that compares numerically (1.10.0 > 1.9.0); null when
-- the text is not x.y.z.
create function private.semver_key(p_version text)
returns int[]
language sql
immutable
set search_path = ''
as $$
  select case when p_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'
    then string_to_array(p_version, '.')::int[] end;
$$;
revoke execute on function private.semver_key(text) from public, anon, authenticated, service_role;

-- The served minimum: the stored value when it reads as x.y.z, else the
-- floor. Never raises, so client_config() cannot fail closed.
create function private.min_supported_app_version()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v text;
begin
  select min_supported_app_version into v from private.app_version_policy where id;
  if private.semver_key(v) is null then
    return '0.1.0';
  end if;
  return v;
exception when others then
  return '0.1.0';
end;
$$;
revoke execute on function private.min_supported_app_version() from public, anon, authenticated, service_role;

create or replace function api_v1.client_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'min_supported_app_version', private.min_supported_app_version(),
    'rules_version', (select version from public.data_versions where key = 'rules'),
    'spots_version', (select version from public.data_versions where key = 'spots'),
    -- Cities whose live counts are still Beta, by name, each once.
    'availability_beta_cities', (
      select coalesce(jsonb_agg(city order by city), '[]'::jsonb)
      from (
        select distinct unnest(cities) as city
        from public.availability_sources
        where enabled and beta
      ) beta_cities
    )
  );
$$;
revoke execute on function api_v1.client_config() from public;
grant execute on function api_v1.client_config() to anon, authenticated, service_role;

-- The one write path. Returns the minimum now in force.
--   admin (aal2):     any x.y.z, up or down; p_reason required.
--   CD (service_role): raise only; lowering or equal is a no-op returning the
--                      current value; p_reason names the run. Audited as the
--                      fixed actor 00000000-0000-0000-0000-0000000000cd.
create function admin_v1.set_min_supported_app_version(p_version text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cd boolean := (select auth.role()) = 'service_role';
  v_actor uuid;
  v_before text := private.min_supported_app_version();
begin
  if not v_cd then
    perform private.require_admin();
  end if;
  if private.semver_key(p_version) is null then
    raise sqlstate 'PT400' using message = 'app_version.invalid',
      detail = jsonb_build_object('field', 'p_version')::text;
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) = 0 or char_length(p_reason) > 400 then
    raise sqlstate 'PT400' using message = 'app_version.reason_required',
      detail = jsonb_build_object('field', 'p_reason')::text;
  end if;
  if v_cd and private.semver_key(p_version) <= private.semver_key(v_before) then
    -- CD never lowers, and an unchanged mark changes nothing.
    return jsonb_build_object('min_supported_app_version', v_before, 'changed', false);
  end if;
  if p_version = v_before then
    return jsonb_build_object('min_supported_app_version', v_before, 'changed', false);
  end if;
  v_actor := case when v_cd then '00000000-0000-0000-0000-0000000000cd'::uuid else auth.uid() end;
  insert into private.app_version_policy(id, min_supported_app_version, updated_at)
  values (true, p_version, now())
  on conflict (id) do update set min_supported_app_version = excluded.min_supported_app_version,
    updated_at = excluded.updated_at;
  insert into public.admin_audit_log(actor, action, target_table, target_id, before, after, note)
  values (v_actor, 'set_min_supported_app_version', 'app_version_policy', 'min_supported_app_version',
    jsonb_build_object('min_supported_app_version', v_before),
    jsonb_build_object('min_supported_app_version', p_version),
    left((case when v_cd then 'CD: ' else '' end) || p_reason, 500));
  return jsonb_build_object('min_supported_app_version', p_version, 'changed', true);
end;
$$;
revoke execute on function admin_v1.set_min_supported_app_version(text, text) from public;
grant execute on function admin_v1.set_min_supported_app_version(text, text) to authenticated, service_role;
