-- 稽核紀錄中的我的地圖照抄文字遮蔽（#275，AUDIT_SCRUB＝A）：202611020100／0110
-- 清掉點位上的原文之後，admin_audit_log 仍有 22 筆（staging：update_spot 18、
-- hide_spot 2、restore_spot 2）的 before／after 帶著當時的原文。比照 #267 的去識別化
-- 例外：
--   1. 對象：target_table 是點位表、before 或 after 含清除前的來源署名「Alan大重停車
--      記事」（清除前每個匯入點的 license_note 都有；清除後新寫的稽核不會再有）。
--   2. 遮蔽：before／after 的 note、entrance_note、parking_guide、special_rules、
--      license_note、source_url、fee_note、fee_source_text 非空時換成固定文字，
--      parking_zones 各區的 fee_note 也換掉（PM_ANS_20261102_157）；其他鍵（結構化
--      費率 fee、旗標、座標、時間…）照留，變更紀錄仍看得出改了哪些欄位。
--   3. 不可修改的觸發器只另外放行「把一列改成它的遮蔽結果」：只有
--      public.admin_audit_mask_mymaps_text() 在交易內設 app.audit_mask_mymaps，
--      其他欄位不變、該列真的含署名。其他修改、刪除、truncate 仍然禁止。
--   4. 執行一次並另寫一筆稽核（只記筆數與 id 範圍）。之後再呼叫找不到要遮蔽的列。

create function private.audit_mymaps_keys() returns text[]
language sql immutable security definer set search_path='' as $$
  select array['note','entrance_note','parking_guide','special_rules','license_note','source_url',
    'fee_note','fee_source_text']
$$;
create function private.audit_mymaps_masked() returns text
language sql immutable security definer set search_path='' as $$ select '（已遮蔽：我的地圖照抄文字，#275）' $$;

-- 一個文字值：非空字串換成固定文字。
create function private.audit_mask_text(p jsonb) returns jsonb
language sql immutable security definer set search_path='' as $$
  select case when jsonb_typeof(p)='string' and p<>'""'::jsonb then to_jsonb(private.audit_mymaps_masked()) else p end
$$;
-- 點位快照是一層的物件，parking_zones 是分區物件的陣列；其他形狀原樣回傳。
create function private.audit_mask_mymaps(p jsonb) returns jsonb
language sql immutable security definer set search_path='' as $$
  select case when jsonb_typeof(p)='object' then (select jsonb_object_agg(e.key,
      case when e.key=any(private.audit_mymaps_keys()) then private.audit_mask_text(e.value)
        when e.key='parking_zones' and jsonb_typeof(e.value)='array' then (
          select coalesce(jsonb_agg(case when jsonb_typeof(z.value)='object' and z.value ? 'fee_note'
              then jsonb_set(z.value,'{fee_note}',private.audit_mask_text(z.value->'fee_note')) else z.value end
            order by z.ord),'[]'::jsonb)
          from jsonb_array_elements(e.value) with ordinality z(value,ord))
        else e.value end)
    from jsonb_each(p) e) else p end
$$;
create function private.audit_has_mymaps(p jsonb) returns boolean
language sql immutable security definer set search_path='' as $$
  select coalesce(strpos(p::text,'Alan大重停車記事')>0,false)
$$;
revoke execute on function private.audit_mymaps_keys(),private.audit_mymaps_masked(),private.audit_mask_text(jsonb),
  private.audit_mask_mymaps(jsonb),private.audit_has_mymaps(jsonb)
  from public,anon,authenticated,service_role;

-- 202611012100_account_data_retention.sql 的守門函式，加上遮蔽的例外。
create or replace function public.admin_audit_log_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if coalesce(current_setting('app.audit_deidentify',true),'')='on'
     and old.deidentified_at is null and new.deidentified_at is not null
     and old.created_at<now()-private.retention_audit_log()
     and (to_jsonb(new)-'target_id'-'before'-'after'-'deidentified_at')
       =(to_jsonb(old)-'target_id'-'before'-'after'-'deidentified_at')
     and new.target_id=private.audit_redact_target(old.target_table,old.target_id)
     and new.before is not distinct from private.audit_redact(old.before)
     and new.after is not distinct from private.audit_redact(old.after) then
    return new;
  end if;
  if coalesce(current_setting('app.audit_mask_mymaps',true),'')='on'
     and old.target_table in ('community_spots','official_heavy_spots')
     and (private.audit_has_mymaps(old.before) or private.audit_has_mymaps(old.after))
     and (to_jsonb(new)-'before'-'after')=(to_jsonb(old)-'before'-'after')
     and new.before is not distinct from private.audit_mask_mymaps(old.before)
     and new.after is not distinct from private.audit_mask_mymaps(old.after) then
    return new;
  end if;
  raise exception 'audit log entries cannot be changed' using errcode='42501';
end $$;
revoke execute on function public.admin_audit_log_guard() from public,anon,authenticated;

-- 遮蔽含我的地圖原文的點位稽核；有處理時另寫一筆稽核（系統操作者 …00de）。
-- 回傳處理的筆數。只給 migration（資料庫擁有者）執行。
create function public.admin_audit_mask_mymaps_text() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer; v_first bigint; v_last bigint;
begin
  perform set_config('app.audit_mask_mymaps','on',true);
  with done as (
    update public.admin_audit_log a
      set before=private.audit_mask_mymaps(a.before),after=private.audit_mask_mymaps(a.after)
      where a.target_table in ('community_spots','official_heavy_spots')
        and (private.audit_has_mymaps(a.before) or private.audit_has_mymaps(a.after))
        and (a.before is distinct from private.audit_mask_mymaps(a.before)
          or a.after is distinct from private.audit_mask_mymaps(a.after))
      returning a.id
  )
  select count(*)::int,min(id),max(id) into v_count,v_first,v_last from done;
  perform set_config('app.audit_mask_mymaps','',true);
  if v_count>0 then
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values('00000000-0000-0000-0000-0000000000de','mask_mymaps_audit_text','admin_audit_log',
      v_first::text||'-'||v_last::text,null,
      jsonb_build_object('entries',v_count,'first_id',v_first,'last_id',v_last,
        'fields',to_jsonb(private.audit_mymaps_keys())),
      '稽核紀錄中的我的地圖照抄文字遮蔽（#275）');
  end if;
  return v_count;
end $$;
revoke execute on function public.admin_audit_mask_mymaps_text() from public,anon,authenticated,service_role;

select public.admin_audit_mask_mymaps_text();
