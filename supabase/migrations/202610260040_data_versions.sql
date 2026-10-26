-- Data versions: an open app learns that spots or rules changed on the
-- backend without polling the big tables (decided 2026-10-26). One row per
-- dataset the app caches; a statement-level trigger on each source table
-- bumps the row, and Realtime publishes the row so every subscribed app
-- reloads what it shows (lib/data/data_updates.dart). A bulk import bumps
-- once per statement, not per row.
--
--   spots  community_spots (reports, imports, moderation) and
--          official_heavy_spots (admin edits, municipal imports)
--   rules  city_rules (admin edits)
create table public.data_versions (
  key text primary key check (key in ('spots','rules')),
  version bigint not null default 1 check (version>0),
  updated_at timestamptz not null default now()
);
insert into public.data_versions(key) values ('spots'),('rules');
alter table public.data_versions enable row level security;
create policy public_data_versions on public.data_versions for select to anon,authenticated using(true);
grant select on public.data_versions to anon,authenticated;

-- Writers (submit-report's service role, admin RPCs, imports) hold no grant
-- on data_versions, so the trigger runs as its owner. Nobody calls it.
create function public.bump_data_version() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  update public.data_versions set version=version+1,updated_at=now() where key=tg_argv[0];
  return null;
end $$;
revoke all on function public.bump_data_version() from public,anon,authenticated;

create trigger community_spots_data_version
  after insert or update or delete or truncate on public.community_spots
  for each statement execute function public.bump_data_version('spots');
create trigger official_heavy_spots_data_version
  after insert or update or delete or truncate on public.official_heavy_spots
  for each statement execute function public.bump_data_version('spots');
create trigger city_rules_data_version
  after insert or update or delete or truncate on public.city_rules
  for each statement execute function public.bump_data_version('rules');

-- Realtime streams data_versions updates to subscribed apps; the select
-- policy above lets anonymous apps receive them. Supabase ships the
-- publication empty, so only the table is added here.
do $$ begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='data_versions') then
    alter publication supabase_realtime add table public.data_versions;
  end if;
end $$;
