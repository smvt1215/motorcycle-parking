-- #195 P2: api_v1.spots_in_viewport(), official and community spots in one
-- read (decided in #195: one viewport API with a source on every spot).
--
-- It serves what the App reads today, merged: viewport_spots_v3 (community)
-- and official_viewport_spots_v3 (official), each capped at 500, so the
-- filtering and the columns stay those functions'. No verdict: the App
-- decides every spot locally (user decision, #195 §7 Q4), and live counts
-- stay in viewport_availability().
--
-- security invoker, unlike the other api_v1 functions: the community layer
-- reads public_spots under the caller's RLS, and a definer would show anon
-- rows the policies hide. Both functions it calls are already granted to
-- anon and authenticated.
--
-- An official layer that fails (e.g. a bad official row) drops only that
-- layer and says so, as the App does now ("官方停車點暫時無法讀取").

create function api_v1.spots_in_viewport(
  south double precision,
  west double precision,
  north double precision,
  east double precision
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_community jsonb;
  v_official jsonb := '[]'::jsonb;
  v_official_failed boolean := false;
  v_truncated boolean := false;
begin
  select coalesce(jsonb_agg(to_jsonb(s) order by s.id), '[]'::jsonb)
  into v_community
  from public.viewport_spots_v3(south, west, north, east) s;
  begin
    select coalesce(jsonb_agg(to_jsonb(o) order by o.id), '[]'::jsonb)
    into v_official
    from public.official_viewport_spots_v3(south, west, north, east) o;
  exception
    -- A bad box is the caller's error, not a missing layer.
    when invalid_parameter_value then raise;
    when others then
      v_official := '[]'::jsonb;
      v_official_failed := true;
  end;
  -- Each layer returns up to 501 rows so a full one reads as truncated.
  if jsonb_array_length(v_community) > 500 or jsonb_array_length(v_official) > 500 then
    v_truncated := true;
  end if;
  return jsonb_build_object(
    'spots', (
      select coalesce(jsonb_agg(e), '[]'::jsonb) from (
        select e from jsonb_array_elements(v_official) with ordinality t(e, n) where n <= 500
        union all
        select e from jsonb_array_elements(v_community) with ordinality t(e, n) where n <= 500
      ) merged
    ),
    'truncated', v_truncated,
    'official_unavailable', v_official_failed
  );
end;
$$;
revoke execute on function api_v1.spots_in_viewport(double precision, double precision, double precision, double precision) from public;
grant execute on function api_v1.spots_in_viewport(double precision, double precision, double precision, double precision)
  to anon, authenticated, service_role;
