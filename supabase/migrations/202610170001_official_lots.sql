-- Official parking lots imported from municipal open data and TDX share the
-- admin-maintained official table. Heavy access is null unless an official
-- source states it; manually entered heavy bays keep the true default.
alter table public.official_heavy_spots
  alter column heavy_allowed drop not null,
  add column source_name text not null default '' check (char_length(source_name)<=60),
  add column source_id text unique check (char_length(source_id) between 1 and 100);
