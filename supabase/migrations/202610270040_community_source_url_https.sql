-- community_spots.source_url gets the https limit official_heavy_spots has had
-- since 202610110001_init.sql (#124): empty, or starting with https://. The
-- app refuses other schemes before launchUrl; this closes every write path
-- (imports, future RPCs, direct SQL) at the table, as it already is for
-- official spots. Riders never set it: apply_report leaves the default and
-- submit-report/validate.ts rejects it; admin_upsert_spot takes it for
-- official spots only, and admin_import_apply writes it for community rows.
-- NOT VALID first so the deploy never fails on a row some path stored, then
-- the few non-conforming values (if any) become empty, as a missing source,
-- and the constraint is validated so it holds for every row.
alter table public.community_spots add constraint community_spots_source_url_check
  check (source_url='' or source_url ~ '^https://') not valid;
update public.community_spots set source_url='',updated_at=now()
  where source_url<>'' and source_url !~ '^https://';
alter table public.community_spots validate constraint community_spots_source_url_check;
