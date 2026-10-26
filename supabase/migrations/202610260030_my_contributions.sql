-- My contributions (docs/CONTRIBUTION_TIERS_FEASIBILITY.md, stage 0): a
-- signed-in rider lists what they sent and how it was handled, in the
-- contribute tab's "我送出的建議".
--
-- moderation_queue has no rider policy (only admin_read_moderation), so this
-- security definer function is the only rider read. It returns the caller's
-- own rows and nothing that identifies anyone: no reporter_id, resolved_by,
-- IP or device hashes, other riders' rows, or the admin's resolution_note
-- (internal text: riders see only the category, resolution_kind from
-- 202610260020, shown as a fixed text per kind; decided 2026-10-25).
--
-- Two kinds of row:
--   report   a suggestion or a "這裡已經不能停車" report (moderation_queue);
--            status pending / accepted (the spot was changed) / rejected /
--            closed (handled without changing the spot, including an
--            accepted report the admin closed with no patch); a rejected or
--            closed one may say why (resolution_kind, null if unclassified).
--   new_spot a spot the rider added (community_spots.user_id);
--            status pending / confirmed / hidden.
-- Spots the rider deleted are gone and not listed.
--
-- Spot name: the current one while the spot is public, else the name the
-- rider saw when reporting (base_spot), so a hidden spot still reads as what
-- was reported without revealing what an admin changed since. Coordinates
-- only come with a public spot, for opening its details.
--
-- Pages: newest first, keyed by (created_at, id); pass the last row's pair
-- to get the next page. At most 50 rows per call.
create function public.my_contributions(
  p_before_at timestamptz default null,
  p_before_id text default null,
  p_limit integer default 20
)
returns table(
  id text,
  kind text,
  spot_id text,
  spot_name text,
  field text,
  summary text,
  status text,
  created_at timestamptz,
  resolved_at timestamptz,
  resolution_kind text,
  spot_visible boolean,
  lat double precision,
  lng double precision
)
language plpgsql stable security definer set search_path='' as $$
declare
  v_user uuid:=auth.uid();
  v_limit integer:=least(greatest(coalesce(p_limit,20),1),50);
begin
  if v_user is null then
    raise exception 'sign-in required' using errcode='42501';
  end if;
  if (p_before_at is null)<>(p_before_id is null) then
    raise exception 'cursor needs both created_at and id' using errcode='22023';
  end if;
  return query
  with mine as (
    select q.id as row_id,q.id::text as id,'report'::text as kind,q.created_at
      from public.moderation_queue q
      where q.reporter_id=v_user
    union all
    select c.id,c.id::text,'new_spot',c.created_at
      from public.community_spots c
      where c.user_id=v_user
  ), page as (
    select m.* from mine m
    where p_before_at is null or (m.created_at,m.id)<(p_before_at,p_before_id)
    order by m.created_at desc,m.id desc
    limit v_limit
  ), detail as (
    select p.id,p.kind,p.created_at,
      q.source_id,q.field,q.reason,q.resolved_at,
      -- "結案不修改" in the admin web is accepted with an empty patch; its
      -- audit entry has no spot. Riders see it as closed, never as adopted.
      case when q.status='accepted' and not exists(
          select 1 from public.admin_audit_log a
          where a.target_table='moderation_queue' and a.target_id=q.id::text
            and a.action='resolve_report' and jsonb_typeof(a.after->'spot')='object')
        then 'closed' else q.status end as q_status,q.resolution_kind,q.base_spot,
      c.name as c_name,c.status as c_status,c.lat as c_lat,c.lng as c_lng,
      o.name as o_name,o.lat as o_lat,o.lng as o_lng,
      (o.id is not null and not o.hidden and o.effective_date<=current_date) as o_visible
    from page p
    left join public.moderation_queue q on p.kind='report' and q.id=p.row_id
    -- source_id is text: a community uuid, official:<uuid>, or an id from a
    -- retired source that matches neither table.
    left join public.community_spots c on c.id=case
      when p.kind='new_spot' then p.row_id
      when q.source_id ~* '^[0-9a-f-]{36}$' then q.source_id::uuid end
    left join public.official_heavy_spots o on o.id=case
      when q.source_id like 'official:%' and substr(q.source_id,10) ~* '^[0-9a-f-]{36}$'
      then substr(q.source_id,10)::uuid end
  ), shaped as (
    select d.*,
      coalesce(d.o_visible,false) or coalesce(d.c_status<>'hidden',false) as visible
    from detail d
  )
  select s.id,s.kind,
    case when s.kind='new_spot' then s.id else s.source_id end,
    case
      when s.kind='new_spot' then s.c_name
      when s.o_visible then s.o_name
      when s.c_status<>'hidden' then s.c_name
      else nullif(s.base_spot->>'name','')
    end,
    s.field,
    case when s.kind='report' then s.reason end,
    case when s.kind='new_spot' then s.c_status else s.q_status end,
    s.created_at,
    s.resolved_at,
    case when s.q_status in ('rejected','closed') then s.resolution_kind end,
    s.visible,
    case when not s.visible then null when s.o_visible then s.o_lat else s.c_lat end,
    case when not s.visible then null when s.o_visible then s.o_lng else s.c_lng end
  from shaped s
  order by s.created_at desc,s.id desc;
end;
$$;
revoke execute on function public.my_contributions(timestamptz,text,integer) from public,anon;
grant execute on function public.my_contributions(timestamptz,text,integer) to authenticated;

-- Each rider's reports without scanning the whole queue; community_spots
-- already has community_spots_user_idx (202610250050).
create index moderation_reporter_idx on public.moderation_queue(reporter_id,created_at desc)
  where reporter_id is not null;
