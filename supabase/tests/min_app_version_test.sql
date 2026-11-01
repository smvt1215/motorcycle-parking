-- 最低支援版本（#195 P2；202611011547_min_app_version.sql）：寧可不擋、
-- 只有 admin_v1.set_min_supported_app_version() 能改、每次修改都留稽核。
begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select no_plan();

create function pg_temp.act(who text) returns void language sql as $$
  select set_config('request.jwt.claims', case who
    when 'admin' then '{"sub":"10000000-0000-4000-8000-000000000005","role":"authenticated","aal":"aal2","app_metadata":{"role":"admin"}}'
    when 'cd' then '{"role":"service_role"}'
    else '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","app_metadata":{"role":"user"}}'
  end, true);
$$;
create function pg_temp.served() returns text language sql as $$
  select api_v1.client_config()->>'min_supported_app_version';
$$;
create function pg_temp.audits() returns bigint language sql as $$
  select count(*) from public.admin_audit_log where action = 'set_min_supported_app_version';
$$;

-- Nobody reaches the setting except through the function.
select ok(not has_table_privilege('anon', 'private.app_version_policy', 'select'), 'anon cannot read the setting');
select ok(not has_table_privilege('authenticated', 'private.app_version_policy', 'update'), 'clients cannot write the setting');
select ok(not has_table_privilege('service_role', 'private.app_version_policy', 'update'), 'CD cannot write the setting directly');
select ok(not has_function_privilege('anon', 'admin_v1.set_min_supported_app_version(text,text)', 'execute'),
  'anon cannot change the minimum');

select is(pg_temp.served(), '0.1.0', 'the minimum starts at the non-blocking 0.1.0');

-- Admin: raises and lowers, each audited with the reason.
select pg_temp.act('admin');
select is(admin_v1.set_min_supported_app_version('1.2.0', '1.2.0 已在兩個商店上架')->>'min_supported_app_version', '1.2.0',
  'an admin raises the minimum');
select is(pg_temp.served(), '1.2.0', 'client_config serves the new minimum');
select is((select note from public.admin_audit_log where action = 'set_min_supported_app_version'
  order by id desc limit 1), '1.2.0 已在兩個商店上架', 'the change is audited with its reason');
select is((select before->>'min_supported_app_version' from public.admin_audit_log
  where action = 'set_min_supported_app_version' order by id desc limit 1), '0.1.0', 'the audit keeps the previous value');
select is(admin_v1.set_min_supported_app_version('1.1.9', '回退：1.2.0 有問題')->>'min_supported_app_version', '1.1.9',
  'an admin may lower it');
select throws_ok($$select admin_v1.set_min_supported_app_version('1.2', 'x')$$, 'PT400', 'app_version.invalid',
  'a version that is not x.y.z is refused');
select throws_ok($$select admin_v1.set_min_supported_app_version('1.3.0', '  ')$$, 'PT400', 'app_version.reason_required',
  'a change needs a reason');

-- A signed-in rider cannot change it.
select pg_temp.act('user');
select throws_ok($$select admin_v1.set_min_supported_app_version('9.9.9', 'x')$$, 'PT403', 'auth.aal2_required',
  'a rider is refused');

-- CD: raise only, audited as the CD actor with the run.
select pg_temp.act('cd');
select is(admin_v1.set_min_supported_app_version('1.10.0', 'https://github.com/x/actions/runs/1')->>'changed', 'true',
  'CD raises the minimum');
select is((select actor::text from public.admin_audit_log where action = 'set_min_supported_app_version'
  order by id desc limit 1), '00000000-0000-0000-0000-0000000000cd', 'CD is audited as the CD actor');
select is((select note from public.admin_audit_log where action = 'set_min_supported_app_version'
  order by id desc limit 1), 'CD: https://github.com/x/actions/runs/1', 'the audit names the run');
select is(pg_temp.audits(), 3::bigint, 'three changes so far');
select is(admin_v1.set_min_supported_app_version('1.9.0', 'run 2')->>'changed', 'false',
  'CD never lowers (versions compare as numbers: 1.9.0 < 1.10.0)');
select is(admin_v1.set_min_supported_app_version('1.10.0', 'run 3')->>'changed', 'false', 'an unchanged mark changes nothing');
select is(pg_temp.audits(), 3::bigint, 'a no-op leaves no audit row');
select is(pg_temp.served(), '1.10.0', 'the minimum stays at the highest raise');
select set_config('request.jwt.claims', '', true);

-- Fail open: missing, malformed or unreadable never blocks anyone.
delete from private.app_version_policy;
select is(pg_temp.served(), '0.1.0', 'no row serves the non-blocking 0.1.0');
alter table private.app_version_policy drop constraint app_version_policy_min_supported_app_version_check;
insert into private.app_version_policy(min_supported_app_version) values ('latest');
select is(pg_temp.served(), '0.1.0', 'a malformed value serves the non-blocking 0.1.0');
drop table private.app_version_policy;
select is(pg_temp.served(), '0.1.0', 'a read error serves the non-blocking 0.1.0');

select * from finish();
rollback;
