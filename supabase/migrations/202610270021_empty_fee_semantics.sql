-- A stored fee = {} names no vehicle, so it holds no structured rate (#114).
-- The admin site's storedFee() (lib/admin/spots/spot_models.dart) already
-- reads it as no fee and lets the admin edit the text freely; until now the
-- server still required such a row's fee_note to be fee_note_of('{}'), so a
-- text edit the form allowed was refused on save. fee null and fee {} now
-- mean the same here too. admin_upsert_spot and admin_resolve_report call
-- this function, so both follow without being redefined.
create or replace function public.fee_note_matches(p_row jsonb) returns boolean
language sql immutable set search_path='' as $$
  select jsonb_typeof(p_row->'fee') is distinct from 'object'
    or p_row->'fee'='{}'::jsonb
    or coalesce(p_row->>'fee_note','請依現場公告')=public.fee_note_of(p_row->'fee');
$$;
revoke execute on function public.fee_note_matches(jsonb) from public,anon;
