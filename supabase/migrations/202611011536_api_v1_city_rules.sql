-- #195 P2: api_v1.city_rules(), every city rule plus the overall rules
-- version in one read (PM answer C: one rules_version for the whole set, the
-- same data_versions value client_config() reports, so the App re-reads
-- exactly when that number moves).
--
-- Rows are served as stored, like city_rules_v2(): expires_on is included and
-- the App applies it itself (the public.city_rules view's masking is for
-- builds before C4). The App decides every verdict locally (user decision,
-- #195 §7 Q4); the server only serves the rules.

create function api_v1.city_rules()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'rules_version', (select version from public.data_versions where key = 'rules'),
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'city', r.city,
        'vehicle', r.vehicle,
        'allowed_space_types', r.allowed_space_types,
        'conditional_space_types', r.conditional_space_types,
        'district_space_types', r.district_space_types,
        'districts', r.districts,
        'restriction', r.restriction,
        'fee_note', r.fee_note,
        'exceptions', r.exceptions,
        'can_use_two_spaces', r.can_use_two_spaces,
        'effective_date', r.effective_date,
        'expires_on', r.expires_on,
        'source_url', r.source_url,
        'version', r.version
      ) order by r.city, r.vehicle)
      from public.city_rules_data r
    ), '[]'::jsonb)
  );
$$;
revoke execute on function api_v1.city_rules() from public;
grant execute on function api_v1.city_rules() to anon, authenticated, service_role;
