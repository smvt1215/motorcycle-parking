-- #326 第 3 項：遮蔽中的點升級成官方點時會抄到替代內容，以及連帶的轉型錯誤。
--
-- 1. admin_promote_spot（202610310300_soft_delete_spots.sql）：點位有處理中的
--    內容檢舉（不論是否觸發遮蔽）或 content_held 非空時拒絕升級：55000
--    「open content reports block promotion」。遮蔽中點位上的名稱與文字是
--    替代內容；審核中的原文也不能直接變成官方資料，所以不改成從 holds 抄。
--    管理員先在檢舉頁結案，再改為官方點。
-- 2. 升級時處理中的回報 source_id 會改成 'official:<id>'。之前已經這樣搬過去
--    的內容檢舉，下面幾處把 source_id 直接轉 uuid 會丟 22P02；改成「點位不在
--    社群表」處理，和投稿者已刪除的點相同：可讀、可結案，回傳形狀不變。
--    - moderation_inappropriate_resolved：不是 uuid 的 source_id 直接略過（沒有
--      社群點可放回）。否則刪除官方點時 spot_deleted_close_reports 的自動結案
--      會讓整筆交易回滾，官方點刪不掉。
--    - admin_v1.content_report、admin_v1.resolve_content_report；case_actions 的
--      report_* 經 private.case_action_apply 呼叫後者，一起修好。
-- 其餘內容與 202610310300_soft_delete_spots.sql、202611021300_content_holds.sql 相同。

-- ===== 1. 升級官方點 =====
CREATE OR REPLACE FUNCTION public.admin_promote_spot(p_source_id text, p_values jsonb, p_base_updated_at timestamp with time zone, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_values jsonb:=coalesce(p_values,'{}'::jsonb);
  v_note text:=coalesce(p_note,'');
  v_community community_spots; v_bad text; v_after jsonb;
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  if p_source_id is null or p_source_id !~* '^[0-9a-f-]{36}$' or jsonb_typeof(v_values)<>'object' or char_length(v_note)>500 then
    raise exception 'invalid promotion' using errcode='22023';
  end if;
  select k into v_bad from jsonb_object_keys(v_values) k where k<>all(public.admin_spot_fields(true)) limit 1;
  if v_bad is not null then raise exception 'field % cannot be set here',v_bad using errcode='22023'; end if;
  if coalesce(v_values->>'source_url','') !~ '^https://' or btrim(coalesce(v_values->>'source_name',''))=''
     or v_values->>'effective_date' is null then
    raise exception 'promotion needs source_name, an https source_url and effective_date' using errcode='22023';
  end if;
  -- An official spot states both vehicles (#201): the admin's call, never
  -- the rider's values, and never reset to unconfirmed.
  if not public.eligibility_values_ok(v_values) or not public.eligibility_stated(v_values) then
    raise exception 'promotion states both vehicles: true, false or not_stated' using errcode='22023';
  end if;
  select * into v_community from community_spots where id=p_source_id::uuid for update;
  if not found then raise exception 'spot not found' using errcode='22023'; end if;
  if v_community.updated_at<>p_base_updated_at then
    raise exception 'spot changed since it was opened' using errcode='40001';
  end if;
  if v_community.status='hidden' then
    raise exception 'restore the spot before promoting it' using errcode='22023';
  end if;
  -- #326：處理中的內容檢舉（不論是否觸發遮蔽）或遮蔽中的點不能升級：點位上
  -- 是替代內容，審核中的原文也不能直接變成官方資料。先處理檢舉再升級。
  if cardinality(v_community.content_held)>0 or exists(select 1 from moderation_queue q
      where q.source_id=v_community.id::text and q.field='inappropriate' and q.resolved_at is null) then
    raise exception 'open content reports block promotion' using errcode='55000';
  end if;

  insert into official_heavy_spots(name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,
      facility_type,facility_types,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,scooter_total,parking_zones,parking_segments,
      source_name,source_url,effective_date,license_note,fee,condition,zones_complete,closure)
    select r.name,r.lat,r.lng,r.city,r.district,r.space_type,r.fee_note,r.note,
      -- Only what the admin states in this call; never the rider's values.
      case when v_values ? 'scooter_allowed' then (v_values->>'scooter_allowed')::boolean end,
      case when v_values ? 'heavy_allowed' then (v_values->>'heavy_allowed')::boolean end,
      coalesce((v_values->>'scooter_not_stated')::boolean,false),coalesce((v_values->>'heavy_not_stated')::boolean,false),
      r.facility_type,r.facility_types,r.parking_access,r.address,r.road_segment,r.entrance_note,r.parking_guide,r.special_rules,r.scooter_total,
      v_community.parking_zones,r.parking_segments,r.source_name,r.source_url,r.effective_date,coalesce(r.license_note,''),
      -- The fee moves with its fee_note text, so the two stay in step.
      r.fee,r.condition,coalesce(r.zones_complete,false),
      -- Works or a closure moves with the spot, as it stands (#116).
      r.closure
    from jsonb_populate_record(
      null::official_heavy_spots,
      (to_jsonb(v_community)-'id'-'user_id'-'location'-'source'-'source_name'-'source_url'-'license_note'
        -'status'-'last_confirmed_at'-'created_at'-'available'-'photo_urls'-'updated_at')||v_values) r
    returning to_jsonb(official_heavy_spots.*) into v_after;

  perform set_config('app.promote','on',true);
  update community_spots set status='hidden',updated_at=now() where id=v_community.id;
  perform set_config('app.promote','',true);
  -- Open reports follow the spot; their snapshots still flag changed fields.
  update moderation_queue set source_id='official:'||(v_after->>'id')
   where source_id=v_community.id::text and status='pending';

  insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values(auth.uid(),'promote_spot','community_spots',v_community.id::text,
    to_jsonb(v_community)-'location',jsonb_build_object('official',v_after),v_note);
  return v_after||jsonb_build_object('source_id','official:'||(v_after->>'id'));
end;
$function$;



-- ===== 2. 任何方式結案：官方點上的檢舉不放回 =====
create or replace function public.moderation_inappropriate_resolved() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- 升級成官方點後的檢舉（source_id 'official:<id>'，#326）：沒有社群點可放回。
  -- 先回傳，下面的轉型才不會在官方點的檢舉上丟 22P02。
  if new.source_id is null or new.source_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  -- 點位刪除時的自動結案不放回：刪除的點 14 天內可能復原（復原時重新送審）。
  if new.field='inappropriate' and new.held and old.resolved_at is null and new.resolved_at is not null
     and not exists(select 1 from public.community_spots c where c.id=new.source_id::uuid and c.deleted_at is not null) then
    perform private.content_hold_release(new.source_id::uuid);
  end if;
  return null;
end $$;


-- ===== 3. 管理站：檢舉詳情與處理（授權不變） =====
create or replace function admin_v1.content_report(p_id text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare q public.moderation_queue; s public.community_spots;
begin
  perform private.require_admin();
  if p_id is null or p_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_id"}';
  end if;
  select * into q from public.moderation_queue m where m.id=p_id::uuid and m.field='inappropriate';
  if q.id is null then raise sqlstate 'PT404' using message='content_report.not_found'; end if;
  -- 升級成官方點後的檢舉（'official:<id>'，#326）：點位不在社群表，和投稿者
  -- 已刪除的點一樣回（spot_deleted、current 各欄位 null）。
  if q.source_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into s from public.community_spots c where c.id=q.source_id::uuid;
  end if;
  return jsonb_build_object(
    'id',q.id::text,'status',q.status,'spot_id',q.source_id,'target',q.proposed->>'target',
    'created_at',q.created_at,'spot_updated_at',s.updated_at,'spot_deleted',s.id is null or s.deleted_at is not null,
    'content_held',coalesce(to_jsonb(s.content_held),'[]'::jsonb),
    'snapshot',(select jsonb_build_object('name',b->'name','contributor_name',b->'contributor_name',
      'note',b->'note','entrance_note',b->'entrance_note','parking_guide',b->'parking_guide','special_rules',b->'special_rules')
      from (select coalesce((select m.base_spot from public.moderation_queue m where m.source_id=q.source_id
        and m.field='inappropriate' and m.proposed->>'target'=q.proposed->>'target'
        and (m.id=q.id or (q.resolved_at is null and m.resolved_at is null))
        order by m.created_at limit 1),'{}'::jsonb) b) x),
    'current',coalesce(private.spot_admin_content(s.id),jsonb_build_object('name',null,'contributor_name',null,
      'note',null,'entrance_note',null,'parking_guide',null,'special_rules',null)),
    'editable_fields',to_jsonb(private.content_editable_fields()),
    'reports',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id::text,'created_at',m.created_at,'note',m.note,
        'held',m.held,'risk_flags',to_jsonb(m.risk_flags),
        'same_network',exists(select 1 from private.content_report_identities a join private.content_report_identities b
          on b.ip_hash=a.ip_hash and b.queue_id<>a.queue_id join public.moderation_queue o on o.id=b.queue_id
          where a.queue_id=m.id and o.source_id=m.source_id and o.field='inappropriate'
            and o.proposed->>'target'=m.proposed->>'target' and o.resolved_at is null))
        order by m.created_at),'[]'::jsonb)
      from public.moderation_queue m where m.source_id=q.source_id and m.field='inappropriate'
        and m.proposed->>'target'=q.proposed->>'target'
        and (m.id=q.id or (q.resolved_at is null and m.resolved_at is null))));
end $$;


create or replace function admin_v1.resolve_content_report(p_id text,p_action text,p_expected_updated_at timestamptz,
  p_patch jsonb default null,p_reason text default null,p_note text default '')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  q public.moderation_queue; s public.community_spots;
  v_note text:=btrim(coalesce(p_note,''));
  v_patch jsonb:=coalesce(p_patch,'{}'::jsonb);
  v_parts text[]; v_ids uuid[]; v_before jsonb; v_after jsonb; v_status text; v_final jsonb:='{}'::jsonb;
begin
  perform private.require_admin();
  if p_id is null or p_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_action is null or p_action not in ('restore','keep','edit') or p_expected_updated_at is null
     or char_length(v_note)>500 then
    raise sqlstate 'PT400' using message='request.invalid';
  end if;
  -- 只接受五個文字欄位、非空字串；點名 1–100 字，其他最多 500 字。
  if jsonb_typeof(v_patch)<>'object'
     or exists(select 1 from jsonb_each(v_patch) e where not e.key=any(private.content_editable_fields())
       or jsonb_typeof(e.value)<>'string' or btrim(e.value#>>'{}')=''
       or char_length(e.value#>>'{}')>case when e.key='name' then 100 else 500 end)
     or btrim(coalesce(v_patch->>'name',''))=private.content_hold_placeholder()
     or (p_action='restore' and v_patch<>'{}'::jsonb)
     or (p_action='edit' and v_patch='{}'::jsonb) then
    raise sqlstate 'PT400' using message='content_report.invalid_patch';
  end if;
  if p_action='restore' and (p_reason is null or p_reason not in ('wrong','duplicate','insufficient','outdated','abuse','other')
     or (p_reason='other' and v_note='')) then
    raise sqlstate 'PT400' using message='content_report.reason_required';
  end if;
  if p_action<>'restore' and p_reason is not null then
    raise sqlstate 'PT400' using message='request.invalid', detail='{"field":"p_reason"}';
  end if;
  select * into q from public.moderation_queue m where m.id=p_id::uuid and m.field='inappropriate' for update;
  if q.id is null then raise sqlstate 'PT404' using message='content_report.not_found'; end if;
  if q.resolved_at is not null then raise sqlstate 'PT409' using message='content_report.already_resolved'; end if;
  -- 升級成官方點後的檢舉（'official:<id>'，#326）：點位不在社群表，和投稿者
  -- 已刪除的點一樣只結案。
  if q.source_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into s from public.community_spots c where c.id=q.source_id::uuid for update;
  end if;
  -- 投稿者已刪除的點、或已升級成官方點：只結案（restore 或 keep，不改內容），spot 只回 id。
  if s.id is null then
    if p_action='edit' or v_patch<>'{}'::jsonb then
      raise sqlstate 'PT404' using message='content_report.spot_not_found';
    end if;
    v_status:=case when p_action='restore' then 'rejected' else 'accepted' end;
    select array_agg(m.id) into v_ids from public.moderation_queue m where m.source_id=q.source_id
      and m.field='inappropriate' and m.resolved_at is null and m.proposed->>'target'=q.proposed->>'target';
    update public.moderation_queue m set status=v_status,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note,
      resolution_kind=case when p_action='restore' then p_reason end where m.id=any(v_ids);
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
      values(auth.uid(),'resolve_content_report','community_spots',q.source_id,
        jsonb_build_object('reports',to_jsonb(v_ids),'spot',case when q.source_id like 'official:%' then 'official' else 'deleted' end),
        jsonb_build_object('action',p_action,'status',v_status,'reason',p_reason),v_note);
    return jsonb_build_object('status',v_status,'resolved_count',cardinality(v_ids),'spot',jsonb_build_object('id',q.source_id));
  end if;
  if s.updated_at is distinct from p_expected_updated_at then
    raise sqlstate 'PT409' using message='content_report.stale',
      detail=jsonb_build_object('updated_at',s.updated_at)::text;
  end if;
  v_parts:=private.content_hold_parts(q.proposed->>'target');
  if p_action='keep' and 'spot_name'=any(v_parts) and not v_patch ? 'name' then
    raise sqlstate 'PT400' using message='content_report.name_required';
  end if;
  v_before:=private.spot_admin_content(s.id)||jsonb_build_object('content_held',to_jsonb(s.content_held));
  v_status:=case when p_action='restore' then 'rejected' else 'accepted' end;
  select array_agg(m.id) into v_ids from public.moderation_queue m where m.source_id=q.source_id
    and m.field='inappropriate' and m.resolved_at is null and m.proposed->>'target'=q.proposed->>'target';
  -- 結案（觸發器放回沒有其他檢舉遮蔽的部分）。
  update public.moderation_queue m set status=v_status,resolved_at=now(),resolved_by=auth.uid(),resolution_note=v_note,
    resolution_kind=case when p_action='restore' then p_reason end
    where m.id=any(v_ids);
  if p_action='keep' then
    if 'text'=any(v_parts) then
      v_final:=jsonb_build_object('note','','entrance_note','','parking_guide','','special_rules','');
    end if;
    if 'rider_name'=any(v_parts) then
      insert into public.contributor_name_clears(spot_id,cleared_by,note) values(s.id,auth.uid(),left(v_note,500))
      on conflict (spot_id) do nothing;
    end if;
  end if;
  v_final:=v_final||v_patch;
  -- 還被其他檢舉遮蔽的部分：處理後的內容直接寫進 holds（不能靠觸發器比對新舊值：
  -- 移除後的空字串和替代內容一樣），點位上維持替代內容；其餘直接寫在點位上。
  update private.content_holds h set original=jsonb_build_object('name',v_final->>'name')
    where h.spot_id=s.id and h.part='spot_name' and v_final ? 'name';
  update private.content_holds h set original=coalesce(h.original,'{}'::jsonb)
      ||(select coalesce(jsonb_object_agg(e.key,e.value),'{}'::jsonb) from jsonb_each(v_final) e
         where e.key=any(private.content_text_fields()))
    where h.spot_id=s.id and h.part='text';
  update public.community_spots c set
    name=coalesce(v_final->>'name',c.name),note=coalesce(v_final->>'note',c.note),
    entrance_note=coalesce(v_final->>'entrance_note',c.entrance_note),
    parking_guide=coalesce(v_final->>'parking_guide',c.parking_guide),
    special_rules=coalesce(v_final->>'special_rules',c.special_rules),
    updated_at=case when v_final<>'{}'::jsonb or (p_action='keep' and 'rider_name'=any(v_parts)) then now() else c.updated_at end
    where c.id=s.id;
  select * into s from public.community_spots c where c.id=s.id;
  v_after:=private.spot_admin_content(s.id)||jsonb_build_object('content_held',to_jsonb(s.content_held));
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values(auth.uid(),'resolve_content_report','community_spots',s.id::text,
      v_before||jsonb_build_object('reports',to_jsonb(v_ids)),
      v_after||jsonb_build_object('action',p_action,'status',v_status,'reason',p_reason),v_note);
  return jsonb_build_object('status',v_status,'resolved_count',cardinality(v_ids),
    'spot',v_after||jsonb_build_object('id',s.id::text,'updated_at',s.updated_at));
end $$;
