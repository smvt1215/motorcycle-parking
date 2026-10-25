-- Admin web P7 (docs/ADMIN_WEB.md): find a rider, see how they report and
-- how close they are to the daily limit, and record bans. Reads stay in the
-- database so a full email address, raw IP or provider identity never leaves
-- it; banning itself needs the Auth Admin API and runs in the `admin-users`
-- Edge Function, which records each change through admin_record_user_ban.

-- Enough to recognise an address a rider wrote in from, not to copy it.
create function public.admin_mask_email(p_email text)
returns text language sql immutable set search_path='' as $$
  select case
    when p_email is null or position('@' in p_email)<2 then ''
    else left(split_part(p_email,'@',1),
        case when char_length(split_part(p_email,'@',1))<=3 then 1 else 2 end)
      ||'***@'||substr(p_email,position('@' in p_email)+1)
  end;
$$;
revoke execute on function public.admin_mask_email(text) from public,anon,authenticated,service_role;

-- One row per account. The query is a user id, a complete email address
-- (matched exactly, shown masked) or part of the display name; empty lists
-- accounts that reported in the last 30 days, most recent first.
create function public.admin_users(p_query text default '',p_limit integer default 50)
returns table(
  id uuid,display_name text,email_masked text,providers text[],is_admin boolean,
  created_at timestamptz,last_sign_in_at timestamptz,banned_until timestamptz,deleted boolean,
  reports_30d integer,last_report_at timestamptz
) language plpgsql stable security definer set search_path='' as $$
declare
  v_query text:=btrim(coalesce(p_query,''));
  v_limit integer:=coalesce(p_limit,50);
  v_since timestamptz:=now()-interval '30 days';
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  -- Cast here: a cast inside the query's CASE could still be evaluated.
  if v_query ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id:=v_query::uuid;
  end if;
  if char_length(v_query)>100 or v_limit not between 1 and 100 then
    raise exception 'invalid user search' using errcode='22023';
  end if;
  return query
  with matched as (
    select u.* from auth.users u
    where case
      when v_query='' then exists(select 1 from public.rate_limit_events r where r.user_id=u.id and r.created_at>=v_since)
      when v_id is not null then u.id=v_id
      when position('@' in v_query)>0 then lower(u.email)=lower(v_query)
      -- Wildcards the admin types are plain text.
      else public.contributor_display_name(u.raw_user_meta_data)
        ilike '%'||replace(replace(replace(v_query,'\','\\'),'%','\%'),'_','\_')||'%'
    end
  ), stats as (
    select m.id,count(r.id)::integer as reports,max(r.created_at) as last_at
    from matched m left join public.rate_limit_events r on r.user_id=m.id and r.created_at>=v_since
    group by m.id
  )
  select m.id,public.contributor_display_name(m.raw_user_meta_data),public.admin_mask_email(m.email),
    coalesce((select array_agg(distinct i.provider order by i.provider) from auth.identities i where i.user_id=m.id),
      case when m.is_anonymous then array['anonymous'] else array[]::text[] end),
    coalesce(m.raw_app_meta_data->>'role','')='admin',
    m.created_at,m.last_sign_in_at,
    case when m.banned_until>now() then m.banned_until end,
    m.deleted_at is not null,
    s.reports,
    (select max(r.created_at) from public.rate_limit_events r where r.user_id=m.id)
  from matched m join stats s on s.id=m.id
  order by s.last_at desc nulls last,m.created_at desc
  limit v_limit;
end;
$$;
revoke execute on function public.admin_users(text,integer) from public,anon;
grant execute on function public.admin_users(text,integer) to authenticated;

-- Everything the user page shows about one account. Network identities are
-- keyed hashes; the page sees a short tag to tell them apart, never the hash.
create function public.admin_user_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_day timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_since timestamptz:=now()-interval '30 days';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  perform 1 from auth.users u where u.id=p_user;
  if not found then raise exception 'user not found' using errcode='22023'; end if;
  return jsonb_build_object(
    'user',(select to_jsonb(a) from public.admin_users(p_user::text,1) a),
    -- apply_report allows 10 reports per account and 30 per network a day (UTC).
    'limits',jsonb_build_object(
      'today',(select count(*) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_day),
      'daily_limit',10,
      'last_7d',(select count(*) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=now()-interval '7 days'),
      'last_30d',(select count(*) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_since),
      'networks_30d',(select count(distinct r.ip_hash) from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_since),
      'shared_accounts_30d',(select count(distinct o.user_id) from public.rate_limit_events o
        where o.created_at>=v_since and o.user_id<>p_user
          and o.ip_hash in (select r.ip_hash from public.rate_limit_events r where r.user_id=p_user and r.created_at>=v_since))),
    'events',coalesce((select jsonb_agg(jsonb_build_object('created_at',e.created_at,'network',left(e.ip_hash,6)) order by e.created_at desc)
      from (select r.created_at,r.ip_hash from public.rate_limit_events r where r.user_id=p_user order by r.created_at desc limit 30) e),'[]'),
    'reports',jsonb_build_object(
      'spots',(select count(*) from public.community_spots s where s.user_id=p_user and s.source='community'),
      'spots_hidden',(select count(*) from public.community_spots s where s.user_id=p_user and s.source='community' and s.status='hidden'),
      'votes_still_there',(select count(*) from public.spot_votes v where v.user_id=p_user and v.vote='still_there'),
      'votes_gone',(select count(*) from public.spot_votes v where v.user_id=p_user and v.vote='gone'),
      'flags_pending',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='pending'),
      'flags_accepted',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='accepted'),
      'flags_rejected',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='rejected'),
      'flags_closed',(select count(*) from public.moderation_queue q where q.reporter_id=p_user and q.status='closed')),
    -- Points this account reported, where its public name can be cleared.
    'spots',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'city',s.city,'district',s.district,
        'status',s.status,'contributor_name',s.contributor_name,'name_cleared',s.cleared,'created_at',s.created_at) order by s.created_at desc)
      from (select c.id,c.name,c.city,c.district,c.status,c.contributor_name,c.created_at,
          exists(select 1 from public.contributor_name_clears n where n.spot_id=c.id) as cleared
        from public.community_spots c where c.user_id=p_user and c.source='community'
        order by c.created_at desc limit 50) s),'[]'),
    'history',coalesce((select jsonb_agg(jsonb_build_object('action',l.action,'note',l.note,'created_at',l.created_at,
        'banned_until',l.after->>'banned_until') order by l.created_at desc)
      from (select * from public.admin_audit_log a where a.target_table='auth.users' and a.target_id=p_user::text
        order by a.created_at desc limit 20) l),'[]')
  );
end;
$$;
revoke execute on function public.admin_user_detail(uuid) from public,anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;

-- The Edge Function calls this with the service role after the Auth Admin API
-- changed the ban; the actor is the admin it verified (role and aal2).
create function public.admin_record_user_ban(p_actor uuid,p_user uuid,p_action text,
  p_before timestamptz,p_after timestamptz,p_duration text,p_note text)
returns bigint language plpgsql security definer set search_path='' as $$
declare
  v_note text:=btrim(coalesce(p_note,''));
  v_id bigint;
begin
  if p_actor is null or p_user is null or p_action is null or p_action not in ('ban_user','unban_user')
     or char_length(v_note) not between 1 and 500 or char_length(coalesce(p_duration,''))>20 then
    raise exception 'invalid user ban record' using errcode='22023';
  end if;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(p_actor,p_action,'auth.users',p_user::text,
    jsonb_build_object('banned_until',p_before),
    jsonb_build_object('banned_until',p_after,'duration',p_duration),v_note)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.admin_record_user_ban(uuid,uuid,text,timestamptz,timestamptz,text,text) from public,anon,authenticated;
grant execute on function public.admin_record_user_ban(uuid,uuid,text,timestamptz,timestamptz,text,text) to service_role;
