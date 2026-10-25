-- Public attribution is a display-name snapshot, never an account identifier
-- or an authorization claim. Imported and admin-added points need only a role.
alter table public.community_spots
  add column contributor_name text not null default '' check (char_length(contributor_name)<=40),
  add column contributor_role text not null default 'rider' check (contributor_role in ('rider','admin','import'));

-- Invoked only by the migration and the private, security-definer trigger.
-- user metadata supplies display text, while only app metadata supplies role.
create function public.spot_contributor_snapshot(p_user uuid,p_source text)
returns table(contributor_name text,contributor_role text)
language sql stable security invoker set search_path='' as $$
  with actor as (
    select u.raw_user_meta_data as metadata,
      case when p_source='import' then 'import'
        when u.raw_app_meta_data->>'role'='admin' then 'admin' else 'rider' end as kind
    from (values(p_user)) requested(id)
    left join auth.users u on u.id=requested.id
  )
  select case when actor.kind='rider' then coalesce((
    select left(candidate.cleaned,40)
    from (
      select priority,btrim(regexp_replace(value,'[[:cntrl:][:space:]]+',' ','g')) as cleaned
      from (values
        (1,case when jsonb_typeof(actor.metadata->'display_name')='string' then actor.metadata->>'display_name' end),
        (2,case when jsonb_typeof(actor.metadata->'full_name')='string' then actor.metadata->>'full_name' end),
        (3,case when jsonb_typeof(actor.metadata->'name')='string' then actor.metadata->>'name' end)
      ) supplied(priority,value)
    ) candidate
    where candidate.cleaned<>'' order by candidate.priority limit 1
  ),'') else '' end,actor.kind
  from actor;
$$;
revoke execute on function public.spot_contributor_snapshot(uuid,text) from public,anon,authenticated,service_role;

-- Backfill names without touching point freshness, source credits or fees.
update public.community_spots s
  set (contributor_name,contributor_role)=(
    select snapshot.contributor_name,snapshot.contributor_role
    from public.spot_contributor_snapshot(s.user_id,s.source) snapshot
  );

create function public.snapshot_spot_contributor() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' then
    -- Editing a point, even through a privileged RPC, cannot replace its author.
    new.contributor_name:=old.contributor_name;
    new.contributor_role:=old.contributor_role;
  else
    select snapshot.contributor_name,snapshot.contributor_role
      into new.contributor_name,new.contributor_role
      from public.spot_contributor_snapshot(new.user_id,new.source) snapshot;
  end if;
  return new;
end;
$$;
revoke execute on function public.snapshot_spot_contributor() from public,anon,authenticated,service_role;
create trigger community_spots_contributor_snapshot before insert or update on public.community_spots
  for each row execute function public.snapshot_spot_contributor();

grant select (contributor_name,contributor_role) on public.community_spots to anon,authenticated;
create or replace view public.public_spots with (security_invoker=true) as
  select id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,
    scooter_total,available,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,
    facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,
    photo_urls,parking_zones,fee,contributor_name,contributor_role
  from public.community_spots;

-- Official rows are maintained by administrators. Keep government attribution,
-- all fee fields and public visibility rules; do not invent an administrator name.
drop function public.official_viewport_spots_v2(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots_v2(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb,
  contributor_name text,contributor_role text
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee,
    ''::text,'admin'::text
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
  order by o.id limit 501;
$$;
grant execute on function public.official_viewport_spots_v2(double precision,double precision,double precision,double precision) to anon,authenticated;

drop function public.official_viewport_spots(double precision,double precision,double precision,double precision);
create function public.official_viewport_spots(south double precision,west double precision,north double precision,east double precision)
returns table(
  id text,source text,source_url text,source_name text,license_note text,name text,lat double precision,lng double precision,
  city text,district text,space_type text,fee_note text,note text,
  heavy_allowed boolean,scooter_allowed boolean,status text,updated_at timestamptz,
  facility_type text,parking_access text,address text,road_segment text,scooter_total integer,
  entrance_note text,parking_guide text,special_rules text,photo_urls jsonb,parking_zones jsonb,fee jsonb,
  contributor_name text,contributor_role text
) language sql stable security invoker set search_path=public as $$
  select 'official:'||o.id,'official',o.source_url,o.source_name,o.license_note,o.name,o.lat,o.lng,
    o.city,o.district,o.space_type,o.fee_note,o.note,
    o.heavy_allowed,o.scooter_allowed,'confirmed',o.updated_at,
    o.facility_type,o.parking_access,o.address,o.road_segment,o.scooter_total,
    o.entrance_note,o.parking_guide,o.special_rules,o.photo_urls,o.parking_zones,o.fee,
    ''::text,'admin'::text
  from public.official_heavy_spots o
  where $1 >= -90 and $3 <= 90 and $2 >= -180 and $4 <= 180
    and $3 > $1 and $4 > $2 and $3-$1 <= 0.5 and $4-$2 <= 0.5
    and o.lat between $1 and $3 and o.lng between $2 and $4
    and o.effective_date <= current_date
    and o.space_type in ('paidMotorcycle','freeMotorcycle','heavyOnly','car','offStreet')
  order by o.id limit 501;
$$;
grant execute on function public.official_viewport_spots(double precision,double precision,double precision,double precision) to anon,authenticated;
