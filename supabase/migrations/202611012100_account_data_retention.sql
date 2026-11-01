-- 帳號相關資料定期清除（#267；使用者決定 2026-11-01）：
--   1. 只用來防濫用、不影響地圖資料的使用紀錄保留 30 天：rate_limit_events
--      （回報限流）、geocode_events（地址查詢限流）。限流與管理站統計的
--      時間窗都在 30 天內（當天、7 天、30 天），刪掉更舊的列不影響。
--      rider_sightings 原本就 7 天刪除（rider-sightings-prune），不重複處理。
--   2. 刪除帳號（#215 的 anonymized_at）滿 180 天後，匿名保留的投票、
--      回報（新增點位的 report_identities）與目擊上的 ip_hash／device_hash
--      清成 null（PM_ANS_20261101_137）。新寫入仍必須有值：觸發器只放行
--      清除排程把雜湊設成 null。計票時清除過的票不算任何網路／裝置：
--      確認數的 count(distinct) 本來就略過 null，負向分數另外排除 null
--      （不然 group by 會把它們併成同一個網路）。
--   3. admin_audit_log 滿 2 年去識別化：target_table 是 auth.users 時拿掉
--      target_id 的 uid，before／after 拿掉個資鍵、貢獻者名稱換成固定文字；
--      actor（管理員本人）照留。不可修改的觸發器只放行「把一列改成它的
--      去識別化結果」這一種修改，其他修改、刪除、truncate 仍然禁止；每次
--      去識別化另寫一筆稽核。
--   4. 每日一個 pg_cron（台灣 04:29）依序執行，客服申請結案 180 天刪除
--      （202611012000，原本獨立排程）一併併入。

-- ===== 0. 期限 =====
create function private.retention_usage_events() returns interval
language sql immutable security definer set search_path='' as $$ select interval '30 days' $$;
create function private.retention_anonymized_hashes() returns interval
language sql immutable security definer set search_path='' as $$ select interval '180 days' $$;
create function private.retention_audit_log() returns interval
language sql immutable security definer set search_path='' as $$ select interval '2 years' $$;
revoke execute on function private.retention_usage_events(),private.retention_anonymized_hashes(),
  private.retention_audit_log()
  from public,anon,authenticated,service_role;

-- ===== 1. 使用紀錄 30 天 =====
-- 每日依 created_at 刪除；原本只有 (user_id,created_at) 與 (ip_hash,created_at)。
create index rate_limit_events_created_idx on public.rate_limit_events(created_at);

create function public.usage_events_prune() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_cut timestamptz:=now()-private.retention_usage_events();
  v_rate integer; v_geocode integer;
begin
  delete from public.rate_limit_events r where r.created_at<v_cut;
  get diagnostics v_rate=row_count;
  delete from public.geocode_events g where g.created_at<v_cut;
  get diagnostics v_geocode=row_count;
  return jsonb_build_object('rate_limit_events',v_rate,'geocode_events',v_geocode);
end $$;
revoke execute on function public.usage_events_prune() from public,anon,authenticated;

comment on table public.rate_limit_events is
  '回報限流紀錄：只防濫用，30 天後由 usage_events_prune() 刪除（#267）。';
comment on table public.geocode_events is
  '地址查詢限流紀錄：只防濫用，30 天後由 usage_events_prune() 刪除（#267）。';

-- ===== 2. 刪帳號後的雜湊 180 天 =====
-- 清除後是 null；兩個雜湊一起清。spot_votes、rider_sightings 只有匿名化過的
-- 列（user_id 是 null、有 anonymized_at）可以沒有雜湊。
alter table public.spot_votes alter column ip_hash drop not null, alter column device_hash drop not null,
  add constraint spot_votes_hashes_retained_check check ((ip_hash is null)=(device_hash is null)
    and (ip_hash is not null or (user_id is null and anonymized_at is not null)));
alter table public.rider_sightings alter column ip_hash drop not null, alter column device_hash drop not null,
  drop constraint rider_sightings_ip_hash_check, drop constraint rider_sightings_device_hash_check,
  add constraint rider_sightings_ip_hash_check check (ip_hash is null or char_length(ip_hash)=64),
  add constraint rider_sightings_device_hash_check check (device_hash is null or char_length(device_hash)=64),
  add constraint rider_sightings_hashes_retained_check check ((ip_hash is null)=(device_hash is null)
    and (ip_hash is not null or (user_id is null and anonymized_at is not null)));
alter table public.report_identities alter column ip_hash drop not null, alter column device_hash drop not null,
  add constraint report_identities_hashes_retained_check check ((ip_hash is null)=(device_hash is null));

-- 新寫入一定要有雜湊（apply_report／apply_sighting 也先擋 null）；改成
-- null 只有 anonymized_hashes_clear() 在交易內設了 app.hash_clear 時可以。
create function public.retained_hashes_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if (new.ip_hash is null or new.device_hash is null)
     and (tg_op='INSERT' or coalesce(current_setting('app.hash_clear',true),'')<>'on') then
    raise exception 'trusted identity hashes are required' using errcode='23502';
  end if;
  return new;
end $$;
revoke execute on function public.retained_hashes_guard() from public,anon,authenticated;
create trigger spot_votes_hashes_retained before insert or update of ip_hash,device_hash on public.spot_votes
  for each row execute function public.retained_hashes_guard();
create trigger report_identities_hashes_retained before insert or update of ip_hash,device_hash on public.report_identities
  for each row execute function public.retained_hashes_guard();
create trigger rider_sightings_hashes_retained before insert or update of ip_hash,device_hash on public.rider_sightings
  for each row execute function public.retained_hashes_guard();

-- 只動雜湊欄位：投票的 spot_votes_history 觸發器只看 vote／created_at，
-- mark_anonymized 只看 user_id，都不會被觸發。
create function public.anonymized_hashes_clear() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_cut timestamptz:=now()-private.retention_anonymized_hashes();
  v_votes integer; v_spots integer; v_sightings integer;
begin
  perform set_config('app.hash_clear','on',true);
  update public.spot_votes v set ip_hash=null,device_hash=null
    where v.anonymized_at<v_cut and v.user_id is null and (v.ip_hash is not null or v.device_hash is not null);
  get diagnostics v_votes=row_count;
  -- 新增點位的回報者雜湊；點位的 anonymized_at 是回報者刪帳號的時間。
  update public.report_identities r set ip_hash=null,device_hash=null
    from public.community_spots c
    where c.id=r.spot_id and c.anonymized_at<v_cut and c.user_id is null
      and (r.ip_hash is not null or r.device_hash is not null);
  get diagnostics v_spots=row_count;
  -- 目擊 7 天就刪，正常不會留到這裡；保險起見一併處理。
  update public.rider_sightings s set ip_hash=null,device_hash=null
    where s.anonymized_at<v_cut and s.user_id is null and (s.ip_hash is not null or s.device_hash is not null);
  get diagnostics v_sightings=row_count;
  perform set_config('app.hash_clear','',true);
  return jsonb_build_object('spot_votes',v_votes,'report_identities',v_spots,'rider_sightings',v_sightings);
end $$;
revoke execute on function public.anonymized_hashes_clear() from public,anon,authenticated;

-- 計票：清除過雜湊的票不算任何網路，負向分數排除它們；其餘與
-- 202611011930_account_deletion.sql 相同。
CREATE OR REPLACE FUNCTION public.apply_report(p_user uuid, p_ip text, p_device text, p_payload jsonb, p_ip_capped boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_action text:=p_payload->>'action'; v_spot jsonb:=p_payload->'spot';
  v_id uuid; v_existing uuid; v_owner uuid; v_qualified boolean; v_score numeric; v_count integer; v_decided timestamptz;
  -- The day resets at midnight in Taiwan (#203).
  v_day timestamptz:=public.report_day_start();
  v_ip_busy boolean:=false;
  -- Precheck holds (submit-report sets them, never the client) and the
  -- notice a rider attaches as evidence (design §4.2, §4.3, §1.4).
  v_flags text[]:=array(select jsonb_array_elements_text(
    case when jsonb_typeof(p_payload->'risk_flags')='array' then p_payload->'risk_flags' else '[]'::jsonb end));
  v_evidence text:=nullif(btrim(coalesce(p_payload->>'evidence_url','')),'');
  v_need integer;
begin
  if p_ip is null or char_length(p_ip)<>64 or p_device is null or char_length(p_device)<>64 then
    raise exception 'missing trusted identity' using errcode='22023';
  end if;
  if not exists(select 1 from auth.users u join auth.identities i on i.user_id=u.id
      where u.id=p_user and not u.is_anonymous and i.provider in ('google','apple')) then
    raise exception 'Google or Apple sign-in required' using errcode='42501';
  end if;
  select created_at<=now()-interval '7 days' into v_qualified from auth.users where id=p_user;
  -- Order is always IP then account: serializes competing requests without deadlocks.
  perform pg_advisory_xact_lock(hashtextextended('ip:'||p_ip,0));
  perform pg_advisory_xact_lock(hashtextextended('user:'||p_user::text,0));
  -- 10 a day per account. Per network 200 a day while App Check only logs
  -- (p_ip_capped); once it is enforced the network count is a risk signal
  -- instead: past 200 the report is kept, marked ip_busy, and goes to review
  -- or weighs less (#203).
  if (select count(*) from rate_limit_events where user_id=p_user and created_at>=v_day)>=10 then
    raise exception 'daily report limit reached' using errcode='P0001';
  end if;
  if (select count(*) from rate_limit_events where ip_hash=p_ip and created_at>=v_day)>=200 then
    if p_ip_capped is not false then
      raise exception 'daily report limit reached' using errcode='P0001';
    end if;
    v_ip_busy:=true;
    -- A new spot opens a case and needs one more confirmation; a flag
    -- carries the signal to the reviewer.
    v_flags:=array_append(v_flags,'ip_busy');
  end if;
  insert into rate_limit_events(user_id,ip_hash,ip_busy) values(p_user,p_ip,v_ip_busy);
  if v_action='create' then
    -- One lock per space type prevents duplicate inserts racing from separate IPs.
    perform pg_advisory_xact_lock(hashtextextended('create:'||(v_spot->>'space_type'),0));
    select id into v_existing from community_spots where status<>'hidden' and space_type=v_spot->>'space_type'
      and extensions.st_dwithin(location,extensions.st_setsrid(extensions.st_makepoint((v_spot->>'lng')::float8,(v_spot->>'lat')::float8),4326)::extensions.geography,15) limit 1;
    if v_existing is not null then return jsonb_build_object('duplicate_id',v_existing);end if;
    -- A rider attaches a notice to a report as evidence; only admins and
    -- imports write a condition's basis (§1.4). validate.ts refuses it first.
    if v_spot->'condition' ? 'basis' or exists(select 1 from jsonb_array_elements(
        case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end
        || case when jsonb_typeof(v_spot->'parking_segments')='array' then v_spot->'parking_segments' else '[]'::jsonb end) z
        where z->'condition' ? 'basis') then
      raise exception 'a report cannot set a condition basis' using errcode='22023';
    end if;
    -- Both vehicles stated (#201): a street spot true or false, a lot also
    -- not_stated; every zone it adds states both. validate.ts refuses the
    -- rest first.
    if not public.eligibility_values_ok(v_spot) or not public.eligibility_stated(v_spot)
       or ((v_spot->>'scooter_not_stated')::boolean or (v_spot->>'heavy_not_stated')::boolean)
         and not public.condition_off_street(v_spot->>'space_type',coalesce(v_spot->>'facility_type',v_spot->'facility_types'->>0))
       or exists(select 1 from jsonb_array_elements(
         case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end) z
         where not public.zone_eligibility_stated(z)) then
      raise exception 'a new spot states both vehicles' using errcode='22023';
    end if;
    insert into community_spots(user_id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,scooter_not_stated,heavy_not_stated,fee,
        facility_type,facility_types,parking_access,entrance_note,parking_guide,parking_zones,parking_segments,condition)
    values(p_user,btrim(v_spot->>'name'),(v_spot->>'lat')::float8,(v_spot->>'lng')::float8,v_spot->>'city',coalesce(v_spot->>'district',''),v_spot->>'space_type',coalesce(v_spot->>'fee_note','請依現場公告'),coalesce(v_spot->>'note',''),(v_spot->>'scooter_allowed')::boolean,(v_spot->>'heavy_allowed')::boolean,
      coalesce((v_spot->>'scooter_not_stated')::boolean,false),coalesce((v_spot->>'heavy_not_stated')::boolean,false),
      case when jsonb_typeof(v_spot->'fee')='object' then v_spot->'fee' end,
      -- Lot details: how the lot is built, who parks where, how to get in and
      -- park, and its zones; submit-report/validate.ts checks their shape.
      nullif(v_spot->>'facility_type',''),
      case when jsonb_typeof(v_spot->'facility_types')='array'
        then array(select jsonb_array_elements_text(v_spot->'facility_types')) end,
      nullif(v_spot->>'parking_access',''),
      btrim(coalesce(v_spot->>'entrance_note','')),btrim(coalesce(v_spot->>'parking_guide','')),
      case when jsonb_typeof(v_spot->'parking_zones')='array' then v_spot->'parking_zones' else '[]'::jsonb end,
      -- A street spot's segments (#188); the trigger gives zones and
      -- segments their ids.
      case when jsonb_typeof(v_spot->'parking_segments')='array' then v_spot->'parking_segments' else '[]'::jsonb end,
      -- The bay's condition; the table check holds it to the contract and
      -- to space_type. Builds without it send none and store null.
      case when jsonb_typeof(v_spot->'condition')='object' then v_spot->'condition' end) returning id into v_id;
    insert into report_identities values(v_id,p_ip,p_device);
    -- A held spot, or one with a notice attached, opens a case so an admin
    -- sees the flags and the link; while it is open, confirming the spot
    -- takes one more vote (feasibility §5.8).
    if cardinality(v_flags)>0 or v_evidence is not null then
      insert into moderation_queue(source_id,reporter_id,reason,field,risk_flags,evidence_url)
      values(v_id::text,p_user,'新增停車點：預檢暫留或附公告連結','create',v_flags,v_evidence)
      on conflict do nothing;
    end if;
  elsif v_action='vote' then
    v_id:=(p_payload->>'spot_id')::uuid;
    if public.spot_deleted(v_id::text) then raise exception 'spot deleted' using errcode='P0410'; end if;
    select user_id into v_owner from community_spots where id=v_id and status<>'hidden' for update;
    -- Found by the row, not its owner: a deleted account's spot has none (#215).
    if not found then raise exception 'spot not found' using errcode='22023';end if;
    if v_owner=p_user then raise exception 'cannot confirm own report' using errcode='42501';end if;
    if exists(select 1 from report_identities where spot_id=v_id and (ip_hash=p_ip or device_hash=p_device)) then v_qualified:=false;end if;
    -- A vote from a busy network weighs as an unqualified one (#203).
    if v_ip_busy then v_qualified:=false; end if;
    insert into spot_votes(spot_id,user_id,vote,qualified,weight,ip_hash,device_hash)
      values(v_id,p_user,p_payload->>'vote',v_qualified,case when v_qualified then 1 else 0.25 end,p_ip,p_device)
      on conflict(spot_id,user_id) do update set vote=excluded.vote,qualified=excluded.qualified,weight=excluded.weight,ip_hash=excluded.ip_hash,device_hash=excluded.device_hash,created_at=now();
    -- Distinct IP AND device, and two qualified users. Network/device sameness cannot inflate confirmations.
    -- count(distinct) skips the votes whose hashes were cleared (#267).
    select least(count(distinct ip_hash),count(distinct device_hash)) into v_count from spot_votes where spot_id=v_id and vote='still_there' and qualified;
    -- A spot created under a hold needs one more confirmation until an
    -- admin resolves its case (feasibility §5.8, decision 17).
    -- Only the spot's own creation counts: a held suggestion is not applied
    -- yet and must not shake the spot's standing.
    v_need:=2+case when exists(select 1 from moderation_queue where source_id=v_id::text
      and field='create' and resolved_at is null and cardinality(risk_flags)>0) then 1 else 0 end;
    -- Once an admin has decided a dispute, the "gone" votes before that
    -- decision are spent: only later ones can reopen it.
    select max(resolved_at) into v_decided from moderation_queue
      where source_id=v_id::text and reason='加權負向回報達門檻' and status<>'pending';
    -- A vote whose hashes were cleared 180 days after its account was
    -- deleted belongs to no network: left out, never merged into one (#267).
    select coalesce(sum(weight),0) into v_score from(select max(weight) as weight from spot_votes where spot_id=v_id and vote='gone'
      and ip_hash is not null
      and created_at>coalesce(v_decided,'-infinity') group by ip_hash) x;
    if v_score>=3 then
      -- Votes alone never take a spot off the map: it drops back to pending
      -- (unverified everywhere) and waits for an admin to hide or keep it.
      update community_spots set status='pending',updated_at=now() where id=v_id;
      insert into moderation_queue(source_id,reason) values(v_id::text,'加權負向回報達門檻') on conflict do nothing;
    else
      -- Only a qualified "still there" is a fresh sighting; other votes keep
      -- the last confirmation time.
      -- A spot an admin kept after a dispute stays confirmed; only a new
      -- dispute can demote it.
      update community_spots set status=case when v_count>=v_need or (status='confirmed' and v_decided is not null) then 'confirmed' else 'pending' end,
        last_confirmed_at=case when v_count>=v_need and p_payload->>'vote'='still_there' and v_qualified then now() else last_confirmed_at end,
        updated_at=now() where id=v_id;
    end if;
  elsif v_action='flag' then
    if public.spot_deleted(p_payload->>'source_id') then raise exception 'spot deleted' using errcode='P0410'; end if;
    insert into moderation_queue(source_id,reporter_id,reason,field,proposed,note,risk_flags,evidence_url)
    values(p_payload->>'source_id',p_user,p_payload->>'reason',nullif(btrim(coalesce(p_payload->>'field','')),''),
      case when jsonb_typeof(p_payload->'proposed')='object' then p_payload->'proposed' end,
      coalesce(p_payload->>'note',''),v_flags,v_evidence)
    on conflict do nothing;
  elsif v_action in ('update','delete') then
    v_id:=(p_payload->>'spot_id')::uuid;
    select user_id into v_owner from community_spots where id=v_id for update;
    if v_owner is distinct from p_user then raise exception 'only owner can edit' using errcode='42501';end if;
    -- Deleted by an admin: the owner can neither restore nor change it.
    if public.spot_deleted(v_id::text) then raise exception 'spot deleted' using errcode='P0410'; end if;
    if v_action='delete' then delete from community_spots where id=v_id;
    else
      -- Edit history (decision 56): the trigger records this update as the
      -- owner's own edit (車友更新).
      perform set_config('app.owner_update',v_id::text,true);
      update community_spots set name=btrim(v_spot->>'name'),fee_note=coalesce(v_spot->>'fee_note',fee_note),note=coalesce(v_spot->>'note',note),status='pending',last_confirmed_at=null,updated_at=now() where id=v_id;
      delete from spot_votes where spot_id=v_id;
    end if;
  else raise exception 'invalid report action' using errcode='22023';
  end if;
  return jsonb_build_object('id',v_id,'accepted',true);
end;
$function$;

revoke all on function public.apply_report(uuid,text,text,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.apply_report(uuid,text,text,jsonb,boolean) to service_role;

-- ===== 3. 稽核紀錄 2 年去識別化 =====
alter table public.admin_audit_log add column deidentified_at timestamptz;
comment on column public.admin_audit_log.deidentified_at is
  '滿 2 年去識別化的時間（#267）：對象使用者的 uid 與 before／after 的個資已拿掉，actor 照留。';
create index admin_audit_log_deidentify_idx on public.admin_audit_log(created_at) where deidentified_at is null;

-- before／after 裡會拿掉的鍵（任何層）。目前實際出現的是 user_id
-- （promote_spot 的點位快照）與 reporter_id（resolve_report 的回報快照）；
-- 其餘是防範日後的快照帶進個資。deleted_by、resolved_by 是管理員，照留。
create function private.audit_personal_keys() returns text[]
language sql immutable security definer set search_path='' as $$
  select array['user_id','reporter_id','email','contact_email','account_hint','avatar_url','picture',
    'full_name','display_name','raw_user_meta_data','ip_hash','device_hash']
$$;
-- 名稱換成這段文字（保留「曾有名稱、後來被清除」的變更紀錄）。
create function private.audit_redacted_name() returns text
language sql immutable security definer set search_path='' as $$ select '（已去識別化）' $$;
-- 對象是使用者時的 target_id。
create function private.audit_redacted_target() returns text
language sql immutable security definer set search_path='' as $$ select 'deidentified' $$;

-- 遞迴去識別化一個 jsonb：拿掉個資鍵，非空的 contributor_name 換成固定文字。
create function private.audit_redact(p jsonb) returns jsonb
language plpgsql immutable security definer set search_path='' as $$
begin
  return case jsonb_typeof(p)
    when 'object' then (select coalesce(jsonb_object_agg(e.key,
        case when e.key='contributor_name' and jsonb_typeof(e.value)='string' and e.value<>'""'::jsonb
          then to_jsonb(private.audit_redacted_name())
          else private.audit_redact(e.value) end),'{}'::jsonb)
      from jsonb_each(p) e where e.key<>all(private.audit_personal_keys()))
    when 'array' then (select coalesce(jsonb_agg(private.audit_redact(x.value) order by x.ord),'[]'::jsonb)
      from jsonb_array_elements(p) with ordinality x(value,ord))
    else p end;
end $$;
create function private.audit_redact_target(p_table text,p_id text) returns text
language sql immutable security definer set search_path='' as $$
  select case when p_table='auth.users' then private.audit_redacted_target() else p_id end
$$;
revoke execute on function private.audit_personal_keys(),private.audit_redacted_name(),
  private.audit_redacted_target(),private.audit_redact(jsonb),private.audit_redact_target(text,text)
  from public,anon,authenticated,service_role;

-- 修改的唯一例外：public.admin_audit_deidentify() 在交易內設 app.audit_deidentify，
-- 而且新的一列必須正好是舊列的去識別化結果（滿 2 年、還沒去識別化、其他
-- 欄位不變）。就算別人也設了這個旗標，能做的也只有提早不了的同一個去識別化。
create function public.admin_audit_log_guard() returns trigger
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
  raise exception 'audit log entries cannot be changed' using errcode='42501';
end $$;
revoke execute on function public.admin_audit_log_guard() from public,anon,authenticated;

drop trigger admin_audit_log_immutable on public.admin_audit_log;
create trigger admin_audit_log_immutable before delete on public.admin_audit_log
  for each row execute function public.admin_audit_log_immutable();
create trigger admin_audit_log_guard before update on public.admin_audit_log
  for each row execute function public.admin_audit_log_guard();

-- 去識別化滿 2 年的稽核，一次最多 p_limit 筆；有處理時另寫一筆稽核
-- （系統操作者 …00de，只記筆數與 id 範圍）。回傳處理的筆數。
create function public.admin_audit_deidentify(p_limit int default 5000) returns integer
language plpgsql security definer set search_path='' as $$
declare
  v_cut timestamptz:=now()-private.retention_audit_log();
  v_count integer; v_changed integer; v_first bigint; v_last bigint;
begin
  perform set_config('app.audit_deidentify','on',true);
  with due as (
    select a.id,
      a.target_id is distinct from private.audit_redact_target(a.target_table,a.target_id)
        or a.before is distinct from private.audit_redact(a.before)
        or a.after is distinct from private.audit_redact(a.after) as changed
    from public.admin_audit_log a
    where a.deidentified_at is null and a.created_at<v_cut
    order by a.created_at,a.id
    limit greatest(1,least(coalesce(p_limit,5000),50000))
    for update skip locked
  ), done as (
    update public.admin_audit_log a
      set target_id=private.audit_redact_target(a.target_table,a.target_id),
        before=private.audit_redact(a.before),after=private.audit_redact(a.after),deidentified_at=now()
    from due where a.id=due.id
    returning a.id,due.changed
  )
  select count(*)::int,count(*) filter (where changed)::int,min(id),max(id)
    into v_count,v_changed,v_first,v_last from done;
  perform set_config('app.audit_deidentify','',true);
  if v_count>0 then
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values('00000000-0000-0000-0000-0000000000de','deidentify_audit_log','admin_audit_log',
      v_first::text||'-'||v_last::text,null,
      jsonb_build_object('entries',v_count,'changed',v_changed,'first_id',v_first,'last_id',v_last,
        'created_before',v_cut),
      '稽核紀錄滿 2 年去識別化（#267）');
  end if;
  return v_count;
end $$;
revoke execute on function public.admin_audit_deidentify(int) from public,anon,authenticated;

-- ===== 4. 每日排程 =====
create function public.account_data_retention() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  return jsonb_build_object(
    'usage_events',public.usage_events_prune(),
    'anonymized_hashes',public.anonymized_hashes_clear(),
    'support_requests',public.support_requests_prune(),
    'audit_log',public.admin_audit_deidentify());
end $$;
revoke execute on function public.account_data_retention() from public,anon,authenticated;

-- 客服申請的清除改由這個排程呼叫（202611012000 註明之後併入 #267）。
select cron.unschedule('support-requests-prune')
  where exists(select 1 from cron.job where jobname='support-requests-prune' and username=current_user);
-- 20:29 UTC＝台灣 04:29，在 account-deletion（03:41）之後，避開其他排程的分鐘。
select cron.schedule('account-data-retention','29 20 * * *','select public.account_data_retention()');
