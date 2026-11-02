-- 我的地圖匯入點的人工修正（#275，PM_ANS_20261102_157），接 202611020100～0120：
--   1. 夾帶評論的 17 個社群點名稱改寫（tool/mymaps_facts.py 的 MANUAL）；名稱中的
--      事實沒有結構化欄位可放，寫成固定句（入口位於…、營業時間、月租、限住宿或
--      消費客人停放、不可過夜停放…）。repo 的 JSON 已用同一份清單改寫。
--   2. 管理員編輯過、清除時排除的點位，照使用者確認的值寫入（tool/mymaps_strip_sql.py
--      的 ADMIN_FIXES）。吉林路汽機車共用車格（9b0e52fb）等時段禁停的結構化決定，
--      本次不動。
-- 每列以名稱與四個文字欄位現值的 md5 比對，被改過的列不會被改。
-- 稽核：每個點位一筆 manual_fix_text（before／after 只有改到的欄位，不含原文），
-- 並另寫一筆摘要。

create temporary table manual_fix(tbl text,id text,guard text,name text,note text,entrance_note text,parking_guide text,special_rules text,
  changed jsonb);

-- manual_fix: 21
insert into pg_temp.manual_fix(tbl,id,guard,name,note,entrance_note,parking_guide,special_rules,changed) select v.column1,v.column2,v.column3,v.column4,v.column5,v.column6,v.column7,v.column8,v.column9::jsonb from (values
  ('c','033a3826-d3dd-522a-990f-6066414d3d96','4a14f8ad212c47b68b576fbdcfe35b1e','綠川東街14號 收費停車場','','','','','{"name": "綠川東街14號 收費停車場"}'),
  ('c','12a51015-95ef-5dec-83f7-8dc68ede31f1','14a95d276637ea502f7dc06b33d0fd0f','城市車旅 社頭停車場','','進場辨識後車牌，出場辨識前車牌','','','{"name": "城市車旅 社頭停車場", "entrance_note": "進場辨識後車牌，出場辨識前車牌"}'),
  ('c','27a66a2c-2f14-5334-a985-060837c13537','ab861bfc0072d886f1da0a298fd82e44','歐特儀 市民廣場地下停車場','','走汽車車道','有重機專用格','','{"name": "歐特儀 市民廣場地下停車場"}'),
  ('c','3788b13c-4088-5133-9a87-42de2b76f2d7','9e864e8ccdce8eaaa757052db0630e5b','中山收費停車場','','走機車車道','可停汽車格','','{"name": "中山收費停車場", "entrance_note": "走機車車道", "parking_guide": "可停汽車格"}'),
  ('c','4453c864-593e-5003-9c77-7b7cafa3d8d6','3772d52093cd6d5c55135fbe5d09254c','臨海新路棧西停車場','24 小時營業','','','來源回報禁止大型重機停放','{"name": "臨海新路棧西停車場", "note": "24 小時營業"}'),
  ('c','49e333f9-0fd3-5519-990d-89829e7463e5','4cb85f1773599f4804128f69665a425f','白沙灣遊客中心第一停車場','','後車牌辨識','','','{"name": "白沙灣遊客中心第一停車場"}'),
  ('c','517015fc-b75f-527b-824c-8dac7f864750','51597b1f6d2225931673749a884d4aaf','松江路25巷38號','','無柵欄','','限時開放：平日夜間19-7 / 假日限定','{"note": "", "entrance_note": "無柵欄"}'),
  ('c','54277bc0-8c80-5eb8-acd2-a9026b2d1875','0ecbc3611a98750cf3228b21b18256e2','舊社捷運站地下停車場','','','','','{"name": "舊社捷運站地下停車場"}'),
  ('c','6049f04f-b466-5435-8dee-a7849e7f6611','af0004eec6b6a5485d0c0989e908e620','白沙灣遊客中心第二停車場','','後車牌辨識','','','{"name": "白沙灣遊客中心第二停車場"}'),
  ('c','69cba8d0-8ab6-5fe7-99e8-17ad4a98767f','5efe806458dac9a8b09032bb77eddf3c','美麗華百樂園','','走機車車道
入口位於敬業四路右側','','','{"entrance_note": "走機車車道\n入口位於敬業四路右側"}'),
  ('c','79dd300d-d87c-5c22-b09b-8a48ec7c2d6b','1dcb7c273a9d1bc6fefb3f6fdf1c8ac4','板橋怡寶大樓停車場','營業時間 07:00–24:00','按鈕取票','','來源回報禁止大型重機停放','{"name": "板橋怡寶大樓停車場", "note": "營業時間 07:00–24:00"}'),
  ('c','8a8a51bc-c0e7-55bd-8436-ff9646ca3d96','d137f883db80c991d225b633ed232513','台灣聯通停車場 石潭場','重機月租每 30 日 1500 元','後車牌辨識','','','{"name": "台灣聯通停車場 石潭場", "note": "重機月租每 30 日 1500 元"}'),
  ('c','a09367d0-f2b7-5deb-9ea8-7adfc41d7cab','ee67a6a15d5f1488d80a20aa9310b7e8','佳音168Parking停車場','','悠遊卡進出','','','{"name": "佳音168Parking停車場"}'),
  ('c','afbb3886-d70a-5e79-95b5-9167a1f31917','2b75002811f13f1e690e716b17dbb392','屏東夜市復興停車場（謙正巷入口）','不可過夜停放','按鈕取票','','','{"name": "屏東夜市復興停車場（謙正巷入口）"}'),
  ('c','bbe52090-0902-546f-a527-1bc02b747125','d76a3838add9bfe90eba11d2b2af8943','秀泰生活嘉義店停車場','','需按鈴或請管理員協助','','','{"name": "秀泰生活嘉義店停車場"}'),
  ('c','ca58918b-524e-55ec-9670-5400d642f5ce','e6527c443718f07e1b4042d1f404bdd9','板橋凱撒大飯店停車場','','按鈕取票','可停汽車格','限住宿或消費客人停放','{"name": "板橋凱撒大飯店停車場", "special_rules": "限住宿或消費客人停放"}'),
  ('c','ecd18f14-6bec-5ddd-91af-7236c2874df1','2da7d6b313b70a455712c84755de32a4','中正運動中心機車停車場（平面）','','無柵欄
入口位於仁愛路','','','{"name": "中正運動中心機車停車場（平面）", "entrance_note": "無柵欄\n入口位於仁愛路"}'),
  ('c','f1826b77-f20b-5f40-9f13-5366fc6ff0c7','154208b35a2bcffd5e4539560fcf4a69','屏東夜市復興停車場（自由路入口）','不可過夜停放','按鈕取票','','','{"name": "屏東夜市復興停車場（自由路入口）"}'),
  ('c','f9bc1271-72ee-5a0e-9f85-b143fa1da16d','e9d36c9987db33622c1b21e0b45c438c','PIT147 重機停車','有月租方案','','','','{"name": "PIT147 重機停車", "note": "有月租方案"}'),
  ('o','0fce7fc1-0704-55f0-ac0a-977c18abfbdb','f62be5c676830563f2c68a9aed397f65','嘟嘟房富邦遼寧大樓站停車場','社群補充（未經官方查核）：大型重機可停；停放區域：機車區（每日 20 元）
已比對臺北市停車場資訊（臺北市停車管理工程處）（TPE1366）','','','','{"note": "社群補充（未經官方查核）：大型重機可停；停放區域：機車區（每日 20 元）\n已比對臺北市停車場資訊（臺北市停車管理工程處）（TPE1366）", "entrance_note": "", "parking_guide": ""}'),
  ('o','e282b9c1-c077-583e-b074-130c11b2db78','bfb46f8747cdec32c0abae3105c84798','三創生活園區停車場','','社群補充（未經官方查核）：
走機車車道','社群補充（未經官方查核）：
有重機專用格
重機停放樓層：B2','','{"entrance_note": "社群補充（未經官方查核）：\n走機車車道", "parking_guide": "社群補充（未經官方查核）：\n有重機專用格\n重機停放樓層：B2"}')
) v;

alter table public.community_spots disable trigger community_spots_flags_from_entries;
alter table public.official_heavy_spots disable trigger official_heavy_spots_flags_from_entries;

do $$
declare v_c integer; v_o integer;
begin
  if not exists(select 1 from public.community_spots c join pg_temp.manual_fix s on s.tbl='c' and c.id=s.id::uuid)
     and not exists(select 1 from public.official_heavy_spots o join pg_temp.manual_fix s on s.tbl='o' and o.id=s.id::uuid) then
    return;
  end if;
  with done as (
    update public.community_spots c
      set name=s.name,note=s.note,entrance_note=s.entrance_note,parking_guide=s.parking_guide,special_rules=s.special_rules
      from pg_temp.manual_fix s
      where s.tbl='c' and c.id=s.id::uuid and c.source='import'
        and md5(concat_ws(chr(31),coalesce(c.name,''),coalesce(c.note,''),coalesce(c.entrance_note,''),
          coalesce(c.parking_guide,''),coalesce(c.special_rules,'')))=s.guard
      returning c.id,s.changed
  ), logged as (
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    select '00000000-0000-0000-0000-0000000000de','manual_fix_text','community_spots',d.id::text,null,d.changed,
      '我的地圖匯入點人工修正（#275，PM_ANS_20261102_157）' from done d
    returning 1
  ) select count(*)::int into v_c from logged;
  with done as (
    update public.official_heavy_spots o
      set name=s.name,note=s.note,entrance_note=s.entrance_note,parking_guide=s.parking_guide,special_rules=s.special_rules
      from pg_temp.manual_fix s
      where s.tbl='o' and o.id=s.id::uuid
        and md5(concat_ws(chr(31),coalesce(o.name,''),coalesce(o.note,''),coalesce(o.entrance_note,''),
          coalesce(o.parking_guide,''),coalesce(o.special_rules,'')))=s.guard
      returning o.id,s.changed
  ), logged as (
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    select '00000000-0000-0000-0000-0000000000de','manual_fix_text','official_heavy_spots',d.id::text,null,d.changed,
      '我的地圖匯入點人工修正（#275，PM_ANS_20261102_157）' from done d
    returning 1
  ) select count(*)::int into v_o from logged;
  insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
  values('00000000-0000-0000-0000-0000000000de','manual_fix_text_summary','spots','275',null,
    jsonb_build_object('community_spots',v_c,'official_heavy_spots',v_o),'我的地圖匯入點人工修正摘要（#275）');
end $$;

alter table public.community_spots enable trigger community_spots_flags_from_entries;
alter table public.official_heavy_spots enable trigger official_heavy_spots_flags_from_entries;
drop table pg_temp.manual_fix;
