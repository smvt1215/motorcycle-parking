-- #235: the fee conversion CLI (tool/convert_fees.dart) writes with the
-- service role, which has no admin session for admin_convert_fees to check.
-- The write itself moves to convert_fees_for(actor, …), unchanged from
-- 202610270022; admin_convert_fees calls it as the signed-in admin, and
-- admin_convert_fees_as calls it for the service role on behalf of an admin
-- account named on the command line, so every conversion is still audited
-- under a person.

create function public.convert_fees_for(p_actor uuid,p_items jsonb,p_note text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  v_note text:=coalesce(p_note,'');
  v_item jsonb; v_id text; v_official boolean; v_target uuid; v_row jsonb;
  v_converted integer:=0; v_skipped jsonb:='[]';
begin
  if p_actor is null then
    raise exception 'an actor is required' using errcode='22023';
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
      -- The note read becomes the fee's source text; fee_note is the fee's
      -- own sentence from now on (§5.5).
      if v_official then
        update official_heavy_spots set fee=v_item->'fee',fee_source_text=fee_note,
          fee_note=public.fee_note_of(v_item->'fee'),updated_at=now() where id=v_target;
      else
        update community_spots set fee=v_item->'fee',fee_source_text=fee_note,
          fee_note=public.fee_note_of(v_item->'fee'),updated_at=now() where id=v_target;
      end if;
      insert into admin_audit_log(actor,action,target_table,target_id,before,after,note)
      values(p_actor,'convert_fee',case when v_official then 'official_heavy_spots' else 'community_spots' end,
        v_target::text,v_row-'space_type',jsonb_build_object('fee',v_item->'fee',
          'fee_note',public.fee_note_of(v_item->'fee'),'fee_source_text',v_row->'fee_note'),v_note);
      v_converted:=v_converted+1;
    end if;
  end loop;
  return jsonb_build_object('converted',v_converted,'skipped',v_skipped);
end;
$$;
revoke execute on function public.convert_fees_for(uuid,jsonb,text) from public,anon,authenticated,service_role;

-- Same signature as before, so its grants stay.
create or replace function public.admin_convert_fees(p_items jsonb,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
begin
  if not public.is_admin() then
    raise exception 'admin with a second factor required' using errcode='42501';
  end if;
  return public.convert_fees_for(auth.uid(),p_items,p_note);
end;
$$;

-- The service role converts on behalf of p_actor, which must be an admin
-- account that is not banned; the note (which run, why) is required.
create function public.admin_convert_fees_as(p_actor uuid,p_items jsonb,p_note text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
begin
  if char_length(btrim(coalesce(p_note,''))) not between 1 and 500 then
    raise exception 'a note of 1 to 500 characters is required' using errcode='22023';
  end if;
  if not exists(select 1 from auth.users u where u.id=p_actor
      and coalesce(u.raw_app_meta_data->>'role','')='admin'
      and (u.banned_until is null or u.banned_until<now())) then
    raise exception 'the actor must be an admin account' using errcode='42501';
  end if;
  return public.convert_fees_for(p_actor,p_items,btrim(p_note));
end;
$$;
revoke execute on function public.admin_convert_fees_as(uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.admin_convert_fees_as(uuid,jsonb,text) to service_role;
