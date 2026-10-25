-- Public attribution shows the reporter's current account name, never an
-- account identifier or an authorization claim. The name column is a public
-- cache kept in sync with the account; imported and admin-added points need
-- only a role, which is fixed when the point is created.
alter table public.community_spots
  add column contributor_name text not null default '' check (char_length(contributor_name)<=40),
  add column contributor_role text not null default 'rider' check (contributor_role in ('rider','admin','import'));
create index community_spots_user_idx on public.community_spots(user_id);

-- Names an administrator removed stay removed, whatever the account later
-- calls itself. Private: only the audited RPC below writes it.
create table public.contributor_name_clears (
  spot_id uuid primary key references public.community_spots(id) on delete cascade,
  cleared_by uuid not null,
  note text not null default '' check (char_length(note)<=500),
  cleared_at timestamptz not null default now()
);
alter table public.contributor_name_clears enable row level security;
revoke all on public.contributor_name_clears from anon,authenticated;

-- A name the user set in the app comes first; a sign-in provider's name is the
-- fallback. User metadata is display text only and never supplies the role.
create function public.contributor_display_name(p_metadata jsonb)
returns text language sql immutable set search_path='' as $$
  select coalesce((
    select left(candidate.cleaned,40)
    from (
      -- Format characters (Unicode Cf: bidi controls, zero-width marks, tags)
      -- are removed so a name cannot be reordered, disguised or made invisible.
      select priority,btrim(regexp_replace(regexp_replace(value,
        '[\u00AD\u0600-\u0605\u061C\u06DD\u070F\u0890\u0891\u08E2\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF\uFFF9-\uFFFB\U000110BD\U000110CD\U00013430-\U0001343F\U0001BCA0-\U0001BCA3\U0001D173-\U0001D17A\U000E0001\U000E0020-\U000E007F]',
        '','g'),'[[:cntrl:][:space:]]+',' ','g')) as cleaned
      from (values
        (1,case when jsonb_typeof(p_metadata->'display_name')='string' then p_metadata->>'display_name' end),
        (2,case when jsonb_typeof(p_metadata->'full_name')='string' then p_metadata->>'full_name' end),
        (3,case when jsonb_typeof(p_metadata->'name')='string' then p_metadata->>'name' end)
      ) supplied(priority,value)
    ) candidate
    where candidate.cleaned<>'' order by candidate.priority limit 1
  ),'');
$$;
revoke execute on function public.contributor_display_name(jsonb) from public,anon,authenticated;

-- Only app metadata, which users cannot write, makes an administrator.
create function public.spot_contributor_role(p_user uuid,p_source text)
returns text language sql stable security invoker set search_path='' as $$
  select case when p_source='import' then 'import'
    when exists(select 1 from auth.users u where u.id=p_user and u.raw_app_meta_data->>'role'='admin') then 'admin'
    else 'rider' end;
$$;
revoke execute on function public.spot_contributor_role(uuid,text) from public,anon,authenticated,service_role;

-- Riders show their current name. Administrators, imports, cleared names and
-- deleted accounts show none.
create function public.spot_contributor_name(p_spot uuid,p_user uuid,p_role text)
returns text language sql stable security invoker set search_path='' as $$
  select case when p_role<>'rider'
      or exists(select 1 from public.contributor_name_clears c where c.spot_id=p_spot) then ''
    else coalesce((select public.contributor_display_name(u.raw_user_meta_data)
      from auth.users u where u.id=p_user and u.deleted_at is null),'') end;
$$;
revoke execute on function public.spot_contributor_name(uuid,uuid,text) from public,anon,authenticated,service_role;

-- Backfill without touching point freshness, source credits or fees.
update public.community_spots s
  set contributor_role=public.spot_contributor_role(s.user_id,s.source);
update public.community_spots s
  set contributor_name=public.spot_contributor_name(s.id,s.user_id,s.contributor_role);

-- Every write path, privileged RPCs included, gets server-derived values:
-- the role is fixed at creation and the name always follows the account.
create function public.community_spot_contributor() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='INSERT' then
    new.contributor_role:=public.spot_contributor_role(new.user_id,new.source);
  else
    new.contributor_role:=old.contributor_role;
  end if;
  new.contributor_name:=public.spot_contributor_name(new.id,new.user_id,new.contributor_role);
  return new;
end;
$$;
revoke execute on function public.community_spot_contributor() from public,anon,authenticated,service_role;
create trigger community_spots_contributor before insert or update on public.community_spots
  for each row execute function public.community_spot_contributor();

-- Renaming or deleting an account updates every point it reported.
create function public.sync_contributor_names() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if public.contributor_display_name(old.raw_user_meta_data) is distinct from public.contributor_display_name(new.raw_user_meta_data)
     or (old.deleted_at is null) is distinct from (new.deleted_at is null) then
    -- The row trigger above recomputes the name from the updated account.
    update public.community_spots s set contributor_name='' where s.user_id=new.id;
  end if;
  return null;
end;
$$;
revoke execute on function public.sync_contributor_names() from public,anon,authenticated,service_role;
create trigger community_contributor_names after update of raw_user_meta_data,deleted_at on auth.users
  for each row execute function public.sync_contributor_names();

-- Moderation: an administrator removes one point's public name, audited.
create function public.admin_clear_contributor_name(p_spot_id uuid,p_note text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_note text:=btrim(coalesce(p_note,''));
  v_before text; v_role text;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_spot_id is null or char_length(v_note)>500 then
    raise exception 'invalid contributor change' using errcode='22023';
  end if;
  select s.contributor_name into v_before from public.community_spots s where s.id=p_spot_id for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  insert into public.contributor_name_clears(spot_id,cleared_by,note)
    values(p_spot_id,auth.uid(),v_note) on conflict(spot_id) do nothing;
  update public.community_spots s set contributor_name='' where s.id=p_spot_id
    returning s.contributor_role into v_role;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'clear_contributor_name','community_spots',p_spot_id::text,
    jsonb_build_object('contributor_name',v_before),jsonb_build_object('contributor_name',''),v_note);
  return jsonb_build_object('id',p_spot_id,'contributor_name','','contributor_role',v_role);
end;
$$;
revoke execute on function public.admin_clear_contributor_name(uuid,text) from public,anon;
grant execute on function public.admin_clear_contributor_name(uuid,text) to authenticated;

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
