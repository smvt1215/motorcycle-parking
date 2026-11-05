-- 刪除帳號網頁登入前的帳號檢查（#270／#268；使用者決定 PM_ANS_20261105_185、_187）。
--
-- 網頁以 Google／Apple 登入後才能申請刪除，但 signInWithIdToken 遇到沒有帳號
-- 的身分會直接建立新帳號。Edge Function deletion-precheck 先驗 ID token，再用
-- 這裡的 helper 以 provider＋sub 查 auth.identities，只回答有沒有帳號；沒有帳號
-- 時網頁就不呼叫 signInWithIdToken。
--
-- 1. private.deletion_precheck_attempts：每網路（IP 的 HMAC，同 submit-report／
--    support-request 的 ip_hash）的嘗試紀錄，只供頻率限制；一小時後刪除。
-- 2. public.deletion_precheck_attempt(ip_hash)：記一次嘗試；同一網路一小時內
--    超過 30 次時拋 deletion_precheck.rate_limited。
-- 3. public.deletion_precheck_has_account(provider, sub)：只回 boolean，不回
--    email 或其他帳號資料。
-- 兩個函式都只給 service_role（Edge Function）。

create table private.deletion_precheck_attempts (
  id bigint generated always as identity primary key,
  ip_hash text not null check (char_length(ip_hash)=64),
  created_at timestamptz not null default now()
);
create index deletion_precheck_attempts_ip_idx on private.deletion_precheck_attempts(ip_hash,created_at);
create index deletion_precheck_attempts_created_idx on private.deletion_precheck_attempts(created_at);
alter table private.deletion_precheck_attempts enable row level security;
revoke all on private.deletion_precheck_attempts from public,anon,authenticated,service_role;
comment on table private.deletion_precheck_attempts is
  'deletion-precheck 的每網路嘗試紀錄（IP 只存 HMAC），只供頻率限制，一小時後刪除（#270）。';

create or replace function public.deletion_precheck_attempt(p_ip_hash text) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
  if p_ip_hash is null or char_length(p_ip_hash)<>64 then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  -- 同一網路同時送來的請求依序計數，不會一起穿過上限。
  perform pg_advisory_xact_lock(hashtextextended('deletion-precheck-ip:'||p_ip_hash,0));
  delete from private.deletion_precheck_attempts a where a.created_at<now()-interval '1 hour';
  if (select count(*) from private.deletion_precheck_attempts a
      where a.ip_hash=p_ip_hash and a.created_at>=now()-interval '1 hour')>=30 then
    raise exception 'deletion_precheck.rate_limited' using errcode='P0001';
  end if;
  insert into private.deletion_precheck_attempts(ip_hash) values(p_ip_hash);
end $$;
revoke execute on function public.deletion_precheck_attempt(text) from public,anon,authenticated;
grant execute on function public.deletion_precheck_attempt(text) to service_role;

create or replace function public.deletion_precheck_has_account(p_provider text,p_sub text) returns boolean
language plpgsql stable security definer set search_path='' as $$
begin
  if p_provider is null or p_provider not in ('google','apple')
     or p_sub is null or char_length(p_sub) not between 1 and 255 then
    raise exception 'request.invalid' using errcode='22023';
  end if;
  -- auth.identities.provider_id 是供應商的 sub（Google、Apple 皆同）。
  return exists(
    select 1 from auth.identities i join auth.users u on u.id=i.user_id
    where i.provider=p_provider and i.provider_id=p_sub and u.deleted_at is null);
end $$;
revoke execute on function public.deletion_precheck_has_account(text,text) from public,anon,authenticated;
grant execute on function public.deletion_precheck_has_account(text,text) to service_role;
