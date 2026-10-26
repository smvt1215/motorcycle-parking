-- Admin Web P6 (docs/ADMIN_WEB.md): import the spots.json files that
-- tool/import_mymaps.py writes, and convert existing fee notes into the
-- structured fee column. Both replace running SQL in the Dashboard.
--
-- Import, like official.sql before it, updates official spots in place and
-- only inserts community spots that are new: an existing community spot
-- belongs to riders' reports and votes from then on. Unlike official.sql it
-- never silently overwrites what an administrator changed. A field counts
-- as the administrator's when the latest audited write that changed it was
-- an administrator's (an edit, an accepted report, a created spot, a fee
-- conversion) and the row still holds that value; the preview marks those
-- fields as conflicts, and apply keeps them unless the administrator names
-- them to overwrite. The overlay table of CONTRIBUTION_TIERS_FEASIBILITY.md
-- §5.6 will later hold such values beside the official ones; until then the
-- audit log is the record. `hidden` and `effective_date` of existing spots
-- are never written, as before.

-- The plan looks up every audited write of each spot in the file; reports
-- and promotions name the spot inside the entry.
create index admin_audit_report_spot_idx on public.admin_audit_log((after->'spot'->>'id'))
  where action='resolve_report';
create index admin_audit_promoted_spot_idx on public.admin_audit_log((after->'official'->>'id'))
  where action='promote_spot';

-- The official columns an import writes; the same list as OFFICIAL_COLUMNS
-- in tool/import_mymaps.py plus fee.
create function public.admin_import_fields() returns text[]
language sql immutable set search_path='' as $$
  select array['name','lat','lng','city','district','space_type','fee_note','note','heavy_allowed','scooter_allowed',
    'source_url','source_name','source_id','license_note','scooter_total','facility_type','parking_access','address',
    'road_segment','entrance_note','parking_guide','special_rules','parking_zones','fee'];
$$;
revoke execute on function public.admin_import_fields() from public,anon;

-- One file entry with every import column, missing keys taken as
-- values_for() in tool/import_mymaps.py does: text empty, zones an empty
-- list, everything else null. Raises on a value of the wrong type.
create function public.admin_import_row(p_spot jsonb,p_official boolean) returns jsonb
language plpgsql stable set search_path=public,pg_temp as $$
declare
  v_fields text[]:=public.admin_import_fields();
  v_text text[]:=array['name','city','district','space_type','fee_note','note','source_url','source_name','license_note',
    'address','road_segment','entrance_note','parking_guide','special_rules'];
  v_input jsonb:='{}'; v_row jsonb; k text;
begin
  foreach k in array v_fields loop
    v_input:=v_input||jsonb_build_object(k,case
      when jsonb_typeof(p_spot->k) is distinct from 'null' and p_spot ? k then p_spot->k
      when k=any(v_text) then to_jsonb(case k when 'fee_note' then '請依現場公告' else '' end)
      when k='parking_zones' then '[]'::jsonb
      else 'null'::jsonb end);
  end loop;
  -- Round-trip through the table's row type, so values compare exactly as
  -- the stored row's to_jsonb does (25.05 vs 25.050, "1" vs 1).
  if p_official then
    select to_jsonb(r) into v_row from jsonb_populate_record(null::official_heavy_spots,v_input) r;
  else
    select to_jsonb(r) into v_row from jsonb_populate_record(null::community_spots,v_input) r;
  end if;
  return (select jsonb_object_agg(f,v_row->f) from unnest(v_fields) f where v_row ? f);
end;
$$;
revoke execute on function public.admin_import_row(jsonb,boolean) from public,anon,authenticated;

-- The plan for a list of file entries: what each would do and which of its
-- changes would overwrite an administrator's value. Shared by preview and
-- apply, so apply never writes what the preview did not show.
create function public.admin_import_plan(p_spots jsonb)
returns table(source_id text,kind text,target uuid,status text,reason text,name text,city text,district text,
  base_updated_at timestamptz,hidden boolean,incoming jsonb,changes jsonb)
language plpgsql stable set search_path=public,pg_temp as $$
declare
  v_spot jsonb; v_index integer:=0; v_seen text[]:='{}';
  v_official boolean; v_raw text; v_current jsonb; v_owned jsonb; k text;
  v_change jsonb;
begin
  for v_spot in select value from jsonb_array_elements(p_spots) loop
    v_index:=v_index+1;
    source_id:=coalesce(v_spot->>'id',''); kind:=null; target:=null; status:=null; reason:='';
    name:=coalesce(v_spot->>'name',''); city:=coalesce(v_spot->>'city',''); district:=coalesce(v_spot->>'district','');
    base_updated_at:=null; hidden:=false; incoming:=null; changes:='[]';
    v_official:=source_id like 'official:%';
    kind:=case when v_official then 'official' else 'community' end;
    v_raw:=case when v_official then substr(source_id,10) else source_id end;
    if jsonb_typeof(v_spot) is distinct from 'object' or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      status:='invalid'; reason:=format('第 %s 筆沒有可辨識的 id',v_index); return next; continue;
    end if;
    target:=v_raw::uuid;
    if source_id=any(v_seen) then
      status:='invalid'; reason:='檔案中重複的 id'; return next; continue;
    end if;
    v_seen:=v_seen||source_id;
    if coalesce(v_spot->>'source','')<>(case when v_official then 'official' else 'import' end) then
      status:='invalid'; reason:='來源與 id 不符（官方點 id 以 official: 開頭，社群點 source 為 import）'; return next; continue;
    end if;
    begin
      incoming:=public.admin_import_row(v_spot,v_official);
    exception when others then
      status:='invalid'; reason:='欄位型別錯誤：'||sqlerrm; return next; continue;
    end;
    if btrim(coalesce(incoming->>'name',''))='' or char_length(incoming->>'name')>100 then
      reason:='名稱需為 1–100 字';
    elsif (incoming->>'lat') is null or (incoming->>'lng') is null
       or (incoming->>'lat')::float8 not between 20 and 27 or (incoming->>'lng')::float8 not between 118 and 123 then
      reason:='座標不在台灣範圍內';
    elsif btrim(coalesce(incoming->>'city',''))='' then
      reason:='缺少縣市';
    elsif v_official and (coalesce(incoming->>'source_url','') !~ '^https://' or btrim(coalesce(incoming->>'source_name',''))='') then
      reason:='官方點需要資料來源與 https 官方資料網址';
    elsif jsonb_typeof(incoming->'fee')='object' and not public.valid_fee(incoming->'fee') then
      reason:='費率格式不符';
    end if;
    if reason<>'' then status:='invalid'; return next; continue; end if;

    if not v_official then
      select to_jsonb(c)-'location' into v_current from community_spots c where c.id=target;
      if v_current is null then status:='new';
      else
        status:='existing'; reason:='社群點已存在，匯入不更新';
        base_updated_at:=(v_current->>'updated_at')::timestamptz;
        hidden:=v_current->>'status'='hidden';
      end if;
      return next; continue;
    end if;

    select to_jsonb(o) into v_current from official_heavy_spots o where o.id=target;
    if v_current is null then status:='new'; return next; continue; end if;
    base_updated_at:=(v_current->>'updated_at')::timestamptz;
    hidden:=(v_current->>'hidden')::boolean;
    -- A file without a fee leaves the stored one while the note it
    -- describes stays the same.
    if incoming->'fee'='null'::jsonb and incoming->'fee_note'=v_current->'fee_note' then
      incoming:=jsonb_set(incoming,'{fee}',v_current->'fee');
    end if;

    -- For each field, the latest audited write that changed it, if that
    -- was an administrator's and the row still holds its value.
    with entries as (
      select a.created_at,a.action,a.before as old_row,a.after as new_row
      from admin_audit_log a
      where a.target_table='official_heavy_spots' and a.target_id=target::text
        and a.action in ('create_spot','update_spot','import_spot','convert_fee')
      union all
      select a.created_at,a.action,a.before->'spot',a.after->'spot' from admin_audit_log a
      where a.action='resolve_report' and a.after->'spot'->>'id'=target::text
        and a.after->>'spot_table'='official_heavy_spots' and a.after->>'status'='accepted'
      union all
      select a.created_at,a.action,null,a.after->'official' from admin_audit_log a
      where a.action='promote_spot' and a.after->'official'->>'id'=target::text
    ),
    writes as (
      select distinct on (f) f,e.action,e.created_at,e.new_row->f as value
      from entries e cross join unnest(public.admin_import_fields()) f
      where e.new_row ? f and (e.old_row is null or (e.old_row->f) is distinct from (e.new_row->f))
      order by f,e.created_at desc
    )
    select coalesce(jsonb_object_agg(w.f,jsonb_build_object('at',w.created_at,'action',w.action)),'{}')
      into v_owned from writes w
      where w.action<>'import_spot' and w.value is not distinct from v_current->w.f;

    foreach k in array public.admin_import_fields() loop
      if (incoming->k) is distinct from (v_current->k) then
        v_change:=jsonb_build_object('field',k,'current',v_current->k,'incoming',incoming->k,'admin',v_owned->k);
        changes:=changes||jsonb_build_array(v_change);
      end if;
    end loop;
    -- A fee is read from its text: when either is the administrator's, both
    -- are kept or replaced together, never a file fee beside a kept text.
    select coalesce(jsonb_agg(case
        when c->>'field' in ('fee','fee_note') and jsonb_typeof(c->'admin') is distinct from 'object'
        then c||jsonb_build_object('admin',(select p->'admin' from jsonb_array_elements(changes) p
          where p->>'field' in ('fee','fee_note') and jsonb_typeof(p->'admin')='object' limit 1))
        else c end order by o),'[]')
      into changes from jsonb_array_elements(changes) with ordinality as e(c,o);
    status:=case when changes='[]'::jsonb then 'unchanged'
      when exists(select 1 from jsonb_array_elements(changes) c where jsonb_typeof(c->'admin')='object') then 'conflict'
      else 'update' end;
    return next;
  end loop;
end;
$$;
revoke execute on function public.admin_import_plan(jsonb) from public,anon,authenticated;

-- What importing p_spots would do, without writing anything. At most 500
-- entries a call; the site sends a large file in parts.
create function public.admin_import_preview(p_spots jsonb) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if jsonb_typeof(p_spots) is distinct from 'array' or jsonb_array_length(p_spots)>500 then
    raise exception 'send at most 500 spots as an array' using errcode='22023';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('source_id',p.source_id,'kind',p.kind,'status',p.status,
      'reason',p.reason,'name',p.name,'city',p.city,'district',p.district,'base_updated_at',p.base_updated_at,
      'hidden',p.hidden,'changes',p.changes))
    from public.admin_import_plan(p_spots) p),'[]');
end;
$$;
revoke execute on function public.admin_import_preview(jsonb) from public,anon;
grant execute on function public.admin_import_preview(jsonb) to authenticated;

-- Import the chosen entries of p_spots. p_choices maps each chosen source_id
-- to {"base_updated_at": the version the preview showed (null for a new
-- spot), "overwrite": [administrator fields to replace]}. Entries not in
-- p_choices are left alone. Each spot is written on its own, so one that
-- fails a table check is reported and the rest still import; every write
-- is audited as import_spot.
create function public.admin_import_apply(p_spots jsonb,p_choices jsonb,p_effective_date date,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_note text:=coalesce(p_note,'');
  v_plan record; v_choice jsonb; v_overwrite text[]; v_patch jsonb; v_kept text[];
  v_before jsonb; v_after jsonb; v_owner uuid;
  v_inserted integer:=0; v_updated integer:=0; v_skipped jsonb:='[]';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if jsonb_typeof(p_spots) is distinct from 'array' or jsonb_array_length(p_spots)>500
     or jsonb_typeof(p_choices) is distinct from 'object' or char_length(v_note)>500 then
    raise exception 'invalid import' using errcode='22023';
  end if;
  -- New community spots join the earlier imports' owner, so they read as
  -- imported rather than as the administrator's own reports.
  select c.user_id into v_owner from community_spots c where c.source='import'
    group by c.user_id order by count(*) desc limit 1;
  v_owner:=coalesce(v_owner,auth.uid());
  -- The verification trigger must not take an import for an administrator
  -- checking vehicle access on site.
  perform set_config('app.import_write','on',true);
  -- Lock what the file touches before planning, so the plan stays true.
  perform 1 from official_heavy_spots o where o.id in (
    select substr(e->>'id',10)::uuid from jsonb_array_elements(p_spots) e
    where e->>'id' ~* '^official:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') for update;

  for v_plan in select * from public.admin_import_plan(p_spots) p where p_choices ? p.source_id loop
    v_choice:=p_choices->v_plan.source_id;
    if v_plan.status in ('invalid','unchanged','existing') then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason',
        case v_plan.status when 'invalid' then v_plan.reason when 'unchanged' then '沒有變更' else v_plan.reason end);
      continue;
    end if;
    -- The preview showed this version; anything else was written since.
    if (case when v_plan.status='new' then v_choice->>'base_updated_at' is not null
         else v_choice->>'base_updated_at' is null
           or (v_choice->>'base_updated_at')::timestamptz is distinct from v_plan.base_updated_at end) then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason','試算後點位已變更，請重新試算');
      continue;
    end if;
    begin
      if v_plan.status='new' then
        if v_plan.kind='official' then
          if p_effective_date is null then raise exception '新增官方點需要生效日期'; end if;
          insert into official_heavy_spots(id,name,lat,lng,city,district,space_type,fee_note,note,heavy_allowed,scooter_allowed,
              source_url,source_name,source_id,license_note,scooter_total,facility_type,parking_access,address,road_segment,
              entrance_note,parking_guide,special_rules,parking_zones,fee,effective_date)
            select v_plan.target,r.name,r.lat,r.lng,r.city,r.district,coalesce(r.space_type,'heavyOnly'),r.fee_note,r.note,r.heavy_allowed,
              r.scooter_allowed,r.source_url,r.source_name,r.source_id,r.license_note,r.scooter_total,r.facility_type,r.parking_access,
              r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.parking_zones,r.fee,p_effective_date
            from jsonb_populate_record(null::official_heavy_spots,v_plan.incoming) r
            returning to_jsonb(official_heavy_spots.*) into v_after;
        else
          insert into community_spots(id,user_id,source,status,name,lat,lng,city,district,space_type,fee_note,note,heavy_allowed,
              scooter_allowed,source_url,source_name,license_note,scooter_total,facility_type,parking_access,address,road_segment,
              entrance_note,parking_guide,special_rules,parking_zones,fee)
            select v_plan.target,v_owner,'import','pending',r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
              r.heavy_allowed,r.scooter_allowed,r.source_url,r.source_name,r.license_note,r.scooter_total,r.facility_type,
              r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.parking_zones,r.fee
            from jsonb_populate_record(null::community_spots,v_plan.incoming) r
            returning to_jsonb(community_spots.*)-'location'-'user_id' into v_after;
        end if;
        v_inserted:=v_inserted+1;
        insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
        values(auth.uid(),'import_spot',case when v_plan.kind='official' then 'official_heavy_spots' else 'community_spots' end,
          v_plan.target::text,null,v_after,v_note);
      else
        v_overwrite:=array(select jsonb_array_elements_text(coalesce(v_choice->'overwrite','[]')));
        -- The fee and its text go together, whichever one was named.
        if v_overwrite && array['fee','fee_note'] then
          v_overwrite:=v_overwrite||array['fee','fee_note'];
        end if;
        select coalesce(jsonb_object_agg(c->>'field',c->'incoming'),'{}'),
               '{}'::text[]
          into v_patch,v_kept
          from jsonb_array_elements(v_plan.changes) c
          where jsonb_typeof(c->'admin') is distinct from 'object' or (c->>'field')=any(v_overwrite);
        v_kept:=array(select c->>'field' from jsonb_array_elements(v_plan.changes) c
          where jsonb_typeof(c->'admin')='object' and not (c->>'field')=any(v_overwrite));
        if v_patch='{}'::jsonb then
          v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason','保留管理員的修改，沒有其他變更');
          continue;
        end if;
        select to_jsonb(o) into v_before from official_heavy_spots o where o.id=v_plan.target;
        update official_heavy_spots o set (name,lat,lng,city,district,space_type,fee_note,note,heavy_allowed,scooter_allowed,
            source_url,source_name,source_id,license_note,scooter_total,facility_type,parking_access,address,road_segment,
            entrance_note,parking_guide,special_rules,parking_zones,fee,updated_at)
          =(select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,r.heavy_allowed,r.scooter_allowed,
            r.source_url,r.source_name,r.source_id,r.license_note,r.scooter_total,r.facility_type,r.parking_access,r.address,
            r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.parking_zones,r.fee,now()
            from jsonb_populate_record(o,v_patch) r)
          where o.id=v_plan.target returning to_jsonb(o) into v_after;
        v_updated:=v_updated+1;
        insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
        values(auth.uid(),'import_spot','official_heavy_spots',v_plan.target::text,v_before,
          v_after||jsonb_build_object('import',jsonb_build_object('kept',to_jsonb(v_kept),
            'overwritten',(select coalesce(jsonb_agg(f),'[]') from unnest(v_overwrite) f where v_patch ? f))),v_note);
      end if;
    exception when others then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_plan.source_id,'reason','資料表拒絕：'||sqlerrm);
    end;
  end loop;
  return jsonb_build_object('inserted',v_inserted,'updated',v_updated,'skipped',v_skipped);
end;
$$;
revoke execute on function public.admin_import_apply(jsonb,jsonb,date,text) from public,anon;
grant execute on function public.admin_import_apply(jsonb,jsonb,date,text) to authenticated;

-- 202610250080_admin_verified_eligibility.sql's trigger, unchanged except
-- that an import write (app.import_write, set only by admin_import_apply for
-- its transaction) is not an administrator's check. The flag can only take
-- away the admin path, so a value set any other way grants nothing.
create or replace function public.community_spots_vehicle_verification() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_admin boolean:=coalesce(public.is_admin(),false)
    and coalesce(current_setting('app.import_write',true),'')<>'on';
  -- Vehicle fields the admin RPC was given, set by admin_upsert_spot and
  -- admin_resolve_report below for the length of the call. It only adds to
  -- what an admin JWT may do, so a value set any other way grants nothing.
  v_stated text[]:=string_to_array(coalesce(current_setting('app.admin_vehicle_fields',true),''),',');
  v_place boolean; v_scooter boolean; v_heavy boolean;
begin
  if tg_op='INSERT' then
    new.scooter_verified_at:=case when v_admin then now() end;
    new.heavy_verified_at:=case when v_admin then now() end;
  else
    -- Never taken from the write itself.
    new.scooter_verified_at:=old.scooter_verified_at;
    new.heavy_verified_at:=old.heavy_verified_at;
    -- Which bay or place the access describes.
    v_place:=new.space_type is distinct from old.space_type
      or new.facility_type is distinct from old.facility_type
      or new.lat is distinct from old.lat or new.lng is distinct from old.lng;
    if v_admin then
      -- Setting or restating a vehicle's access, or the shared access that
      -- states both, verifies it. Moving the spot or changing its bay
      -- without restating the access voids the old check, which was made
      -- for the old place.
      v_scooter:=new.scooter_allowed is distinct from old.scooter_allowed
        or new.parking_access is distinct from old.parking_access
        or v_stated && array['scooter_allowed','parking_access'];
      v_heavy:=new.heavy_allowed is distinct from old.heavy_allowed
        or new.parking_access is distinct from old.parking_access
        or v_stated && array['heavy_allowed','parking_access'];
      if v_scooter then new.scooter_verified_at:=now();
      elsif v_place then new.scooter_verified_at:=null;
      end if;
      if v_heavy then new.heavy_verified_at:=now();
      elsif v_place then new.heavy_verified_at:=null;
      end if;
    else
      -- Anything else that changes what was verified voids it: the flag
      -- itself, the shared access, or which bay or place it describes.
      v_place:=v_place or new.parking_access is distinct from old.parking_access;
      if v_place or new.scooter_allowed is distinct from old.scooter_allowed then
        new.scooter_verified_at:=null;
      end if;
      if v_place or new.heavy_allowed is distinct from old.heavy_allowed then
        new.heavy_verified_at:=null;
      end if;
    end if;
  end if;
  -- An unknown flag has nothing to verify.
  if new.scooter_allowed is null then new.scooter_verified_at:=null; end if;
  if new.heavy_allowed is null then new.heavy_verified_at:=null; end if;
  return new;
end;
$$;

-- Fee conversion. The site reads each note with lib/admin/import/
-- fee_reading.dart and shows what it can convert, what stays unconfirmed and
-- what needs a person; only what the administrator confirms is written.

-- Spots that have a fee note but no structured fee yet, both tables,
-- hidden ones included so a restored spot is not left behind.
create function public.admin_fee_backlog()
returns table(source_id text,kind text,name text,city text,district text,space_type text,fee_note text,
  updated_at timestamptz,hidden boolean)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  return query
    select c.id::text,'community',c.name,c.city,c.district,c.space_type,c.fee_note,c.updated_at,c.status='hidden'
      from community_spots c where c.fee is null
    union all
    select 'official:'||o.id,'official',o.name,o.city,o.district,o.space_type,o.fee_note,o.updated_at,o.hidden
      from official_heavy_spots o where o.fee is null
    order by 7,1;
end;
$$;
revoke execute on function public.admin_fee_backlog() from public,anon;
grant execute on function public.admin_fee_backlog() to authenticated;

-- Write confirmed fees: p_items is [{source_id, fee_note, space_type, fee}],
-- at most 500. The reading depends on both the note and the space type (an
-- amount on a heavy-only bay is the heavy rate), so a spot whose note or
-- space type changed since it was read, or that already has a fee, is
-- skipped rather than overwritten. fee_note is left as written. Audited
-- per spot as convert_fee.
create function public.admin_convert_fees(p_items jsonb,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_note text:=coalesce(p_note,'');
  v_item jsonb; v_id text; v_official boolean; v_target uuid; v_row jsonb;
  v_converted integer:=0; v_skipped jsonb:='[]';
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)>500 or char_length(v_note)>500 then
    raise exception 'send at most 500 fees as an array' using errcode='22023';
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_id:=coalesce(v_item->>'source_id','');
    v_official:=v_id like 'official:%';
    v_target:=case when (case when v_official then substr(v_id,10) else v_id end)
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (case when v_official then substr(v_id,10) else v_id end)::uuid end;
    if v_target is null then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_id,'reason','無法辨識的點位');
      continue;
    end if;
    if jsonb_typeof(v_item->'fee') is distinct from 'object' or not public.valid_fee(v_item->'fee')
       or v_item->'fee'='{}'::jsonb then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_id,'reason','費率格式不符');
      continue;
    end if;
    if v_official then
      select jsonb_build_object('fee',o.fee,'fee_note',o.fee_note,'space_type',o.space_type) into v_row
        from official_heavy_spots o where o.id=v_target for update;
    else
      select jsonb_build_object('fee',c.fee,'fee_note',c.fee_note,'space_type',c.space_type) into v_row
        from community_spots c where c.id=v_target for update;
    end if;
    if v_row is null then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_id,'reason','找不到點位');
    elsif v_row->'fee'<>'null'::jsonb then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_id,'reason','已有結構化費率');
    elsif v_row->>'fee_note' is distinct from v_item->>'fee_note' then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_id,'reason','費率說明已變更，請重新讀取');
    elsif v_row->>'space_type' is distinct from v_item->>'space_type' then
      v_skipped:=v_skipped||jsonb_build_object('source_id',v_id,'reason','格位類型已變更，請重新讀取');
    else
      if v_official then
        update official_heavy_spots set fee=v_item->'fee',updated_at=now() where id=v_target;
      else
        update community_spots set fee=v_item->'fee',updated_at=now() where id=v_target;
      end if;
      insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
      values(auth.uid(),'convert_fee',case when v_official then 'official_heavy_spots' else 'community_spots' end,
        v_target::text,v_row-'space_type',jsonb_build_object('fee',v_item->'fee','fee_note',v_row->'fee_note'),v_note);
      v_converted:=v_converted+1;
    end if;
  end loop;
  return jsonb_build_object('converted',v_converted,'skipped',v_skipped);
end;
$$;
revoke execute on function public.admin_convert_fees(jsonb,text) from public,anon;
grant execute on function public.admin_convert_fees(jsonb,text) to authenticated;
