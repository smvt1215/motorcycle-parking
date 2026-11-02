"""Generate the one-off migrations that strip My Maps text already in the database (#275).

Input is a read-only dump of the affected rows (`select to_jsonb(t) …`, kept
outside the repo); output is a migration holding only the new, fact-only
values. No original text goes into the migration: each row is guarded by the
md5 of the values it replaces, so a row that changed since the dump (or that
a database never had) is left alone.

  --layer text  note, entrance_note, parking_guide, special_rules (mymaps_facts.scrub_spot)
  --layer fee   fee_note and fee_source_text without a structured fee, zone fee notes,
                and the fee parentheses in official notes (mymaps_facts.scrub_fee_text),
                computed on top of the text layer

Spots an administrator has edited (an update_spot audit entry) are skipped and
listed in the migration's header, for review by hand.
"""
import argparse
import hashlib
import json
from pathlib import Path

from mymaps_facts import scrub_fee_text, scrub_spot, scrub_summary_fees

TEXT = ("note", "entrance_note", "parking_guide", "special_rules")
SEP = "\x1f"  # chr(31) in SQL


def guard(*values):
    """md5 of the values joined by chr(31), as SQL `md5(concat_ws(chr(31), …))` with null as ''."""
    return hashlib.md5(SEP.join(v or "" for v in values).encode()).hexdigest()


def jsonb_text(value):
    """`value::jsonb::text` as Postgres prints it: keys by length then bytes, `, ` and `: ` separators."""
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: (len(k.encode()), k.encode()))
        return "{" + ", ".join(f"{jsonb_text(k)}: {jsonb_text(value[k])}" for k in keys) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(jsonb_text(v) for v in value) + "]"
    return json.dumps(value, ensure_ascii=False)


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def load(backup):
    rows = lambda name: [r["row"] for r in json.loads((Path(backup) / f"{name}.json").read_text())]
    edited = {r["target_id"] for r in rows("admin_audit_log_spots") if r["action"] == "update_spot"}
    community = [r for r in rows("community_spots") if (r.get("license_note") or "").startswith("整理自 Alan大重停車記事")]
    official = [r for r in rows("official_heavy_spots") if "Alan大重停車記事" in (r.get("license_note") or "")]
    return community, official, edited


def text_changes(spot, official):
    new = scrub_spot(spot, official)
    return new if any((spot.get(k) or "") != new[k] for k in TEXT) else None


def after_text(spot, official):
    return spot | (text_changes(spot, official) or {})


def fee_changes(spot, official):
    """New fee fields of a spot after the text layer, or None when nothing changes."""
    spot = after_text(spot, official)
    new = {}
    if official:
        note = scrub_summary_fees(spot.get("note") or "")
        if note != (spot.get("note") or ""):
            new["note"] = note
    else:
        if not spot.get("fee"):  # beside a fee, fee_note is the database's own sentence (fee_note_of)
            fee_note = scrub_fee_text(spot.get("fee_note") or "")
            if fee_note != spot.get("fee_note"):
                new["fee_note"] = fee_note
        if spot.get("fee_source_text"):
            source = scrub_fee_text(spot["fee_source_text"])
            if source != spot["fee_source_text"]:
                new["fee_source_text"] = source
        zones = [z | {"fee_note": scrub_fee_text(z["fee_note"])} if isinstance(z.get("fee_note"), str) and z["fee_note"] else z
                 for z in spot.get("parking_zones") or []]
        if zones != (spot.get("parking_zones") or []):
            new["parking_zones"] = zones
    return new or None


def summary(value, limit=40):
    value = (value or "").replace("\n", " / ")
    return value if len(value) <= limit else value[:limit - 1] + "…"


def edited_list(community, official, edited, layer):
    """(table, id, field, current value summary) for the administrator-edited spots this layer would change."""
    out = []
    for table, rows, is_official in (("community_spots", community, False), ("official_heavy_spots", official, True)):
        for spot in rows:
            if spot["id"] not in edited:
                continue
            new = text_changes(spot, is_official) if layer == "text" else fee_changes(spot, is_official)
            base = spot if layer == "text" else after_text(spot, is_official)
            for field, value in (new or {}).items():
                if value != (base.get(field) or ("" if field != "parking_zones" else [])):
                    current = base.get(field)
                    out.append((table, spot["id"], field, summary(current if isinstance(current, str) else jsonb_text(current))))
    return out


def text_sql(community, official, edited):
    parts = []
    for table, rows, is_official in (("community_spots", community, False), ("official_heavy_spots", official, True)):
        values = []
        for spot in rows:
            new = text_changes(spot, is_official)
            if new and spot["id"] not in edited:
                old = guard(*(spot.get(k) for k in TEXT))
                values.append(f"  ('{spot['id']}','{old}',{','.join(literal(new[k]) for k in TEXT)})")
        parts.append((table, values))
    return parts


def fee_sql(community, official, edited):
    community_values, official_values = [], []
    for spot in community:
        new = fee_changes(spot, False)
        if new and spot["id"] not in edited:
            base = after_text(spot, False)
            zones = base.get("parking_zones") or []
            old = guard(base.get("fee_note"), base.get("fee_source_text"), jsonb_text(zones))
            merged = {"fee_note": base.get("fee_note") or "", "fee_source_text": base.get("fee_source_text") or "",
                      "parking_zones": zones} | new
            community_values.append(f"  ('{spot['id']}','{old}',{literal(merged['fee_note'])},{literal(merged['fee_source_text'])},"
                                    f"{literal(json.dumps(merged['parking_zones'], ensure_ascii=False))})")
    for spot in official:
        new = fee_changes(spot, True)
        if new and spot["id"] not in edited:
            base = after_text(spot, True)
            official_values.append(f"  ('{spot['id']}','{guard(base.get('note'))}',{literal(new['note'])})")
    return community_values, official_values


TEXT_HEAD = """-- 我的地圖照抄文字清除（#275，PM_ANS_20261101_132）：社群協力平台只留已核驗的
-- 事實。範圍只限盤點報告的判斷依據：community_spots 的我的地圖匯入（license_note
-- 開頭「整理自 Alan大重停車記事」），以及 official_heavy_spots 中有我的地圖社群補充
-- 的官方點（license_note 含「Alan大重停車記事」）。
--   1. note、entrance_note、parking_guide、special_rules 逐行比對（tool/mymaps_facts.py
--      的 scrub_spot）：短事實行改寫成固定詞彙，其餘照抄行、「來源原名稱：…」與圖示
--      顏色轉成的句子刪除；只剩「社群補充（未經官方查核）：」標頭的欄位整欄清空。
--   2. license_note 只寫「社群協力資料，經核驗後只收錄事實」（官方點前面保留政府
--      資料開放授權條款）；社群點的 source_url（來源地圖網址）清空。
-- 下方的值由 tool/mymaps_strip_sql.py 從清除前的唯讀備份（不進版控）產生，只含新值。
-- 每列以舊值的 md5 比對，備份後被改過的列（或沒有這批資料的資料庫）不會被改。
-- 管理員編輯過的點位（admin_audit_log 有 update_spot）的這四欄不在此處理，另案人工
-- 確認（license_note 仍一併更新）：
{edited}
-- updated_at 不動：內容沒有新的事實，只是拿掉文字；App 依 data_versions 重新下載。
-- 最後寫一筆稽核摘要（只記筆數與欄位，不記內容）。

create temporary table strip_text(tbl text,id text,guard text,note text,entrance_note text,parking_guide text,special_rules text);

"""

TEXT_TAIL = """
-- 只改文字：停車資格觸發器在任何更新時都會依分區重算 scooter_allowed／heavy_allowed，
-- 有些匯入點的旗標和分區不一致（另案處理），這裡不順帶改變它們。
alter table public.community_spots disable trigger community_spots_flags_from_entries;
alter table public.official_heavy_spots disable trigger official_heavy_spots_flags_from_entries;

do $$
declare v_c integer; v_o integer; v_lc integer; v_lo integer;
begin
  -- A database without this import (production before it, local test databases)
  -- changes nothing, not even the spots data version.
  if not exists(select 1 from public.community_spots where source='import' and license_note like '整理自 Alan大重停車記事%')
     and not exists(select 1 from public.official_heavy_spots
       where license_note like '%Alan大重停車記事%' or license_note='政府資料開放授權條款第 1 版；') then
    return;
  end if;
  update public.community_spots c
    set note=s.note,entrance_note=s.entrance_note,parking_guide=s.parking_guide,special_rules=s.special_rules
    from pg_temp.strip_text s
    where s.tbl='c' and c.id=s.id::uuid and c.source='import'
      and md5(concat_ws(chr(31),coalesce(c.note,''),coalesce(c.entrance_note,''),coalesce(c.parking_guide,''),
        coalesce(c.special_rules,'')))=s.guard;
  get diagnostics v_c=row_count;
  update public.official_heavy_spots o
    set note=s.note,entrance_note=s.entrance_note,parking_guide=s.parking_guide,special_rules=s.special_rules
    from pg_temp.strip_text s
    where s.tbl='o' and o.id=s.id::uuid
      and md5(concat_ws(chr(31),coalesce(o.note,''),coalesce(o.entrance_note,''),coalesce(o.parking_guide,''),
        coalesce(o.special_rules,'')))=s.guard;
  get diagnostics v_o=row_count;
  -- 資料來源聲明不加註來源名稱，社群點也不留來源地圖的網址（PM_ANS_20261102_157）。
  update public.community_spots set license_note='社群協力資料，經核驗後只收錄事實',source_url=''
    where source='import' and license_note like '整理自 Alan大重停車記事%';
  get diagnostics v_lc=row_count;
  update public.official_heavy_spots set license_note=case
      when license_note like '%Alan大重停車記事%' then '政府資料開放授權條款第 1 版；社群協力資料，經核驗後只收錄事實'
      else '政府資料開放授權條款第 1 版' end
    where license_note like '%Alan大重停車記事%' or license_note='政府資料開放授權條款第 1 版；';
  get diagnostics v_lo=row_count;
  if v_c+v_o+v_lc+v_lo>0 then
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values('00000000-0000-0000-0000-0000000000de','strip_copied_text','spots','275',null,
      jsonb_build_object('community_spots',v_c,'official_heavy_spots',v_o,
        'license_community',v_lc,'license_official',v_lo,
        'fields',jsonb_build_array('note','entrance_note','parking_guide','special_rules','license_note','source_url')),
      '我的地圖照抄文字清除，只留固定詞彙的事實（#275）');
  end if;
end $$;

alter table public.community_spots enable trigger community_spots_flags_from_entries;
alter table public.official_heavy_spots enable trigger official_heavy_spots_flags_from_entries;
drop table pg_temp.strip_text;
"""

FEE_HEAD = """-- 我的地圖費率片段清除（#275，接 202611020100）：費率簡寫夾帶的原文片段（需按鈴、
-- 後牌、B2限悠遊卡…）對得上 tool/mymaps_facts.py 詞彙表的轉成固定詞，其餘刪除。
--   - community_spots：沒有結構化 fee 的 fee_note（有 fee 時 fee_note 是 fee_note_of(fee)
--     產生的句子，不動）、fee_source_text、parking_zones 各區的 fee_note。
--   - official_heavy_spots：note 社群補充摘要中，各停放區域括號內的費率。
--   官方費率文字、試辦費率與臺北市路邊收費句子是官方或工具自己的句子，不動。
-- fee 不變，所以 spot_fee_source_text() 不會清掉 fee_source_text；parking_zones 只改
-- fee_note，區域 id 與其他鍵保留。
-- 下方的值由 tool/mymaps_strip_sql.py --layer fee 產生，以 202611020100 清除後的值為準，
-- 每列以舊值的 md5 比對。管理員編輯過的點位不處理：
{edited}

create temporary table strip_fee_c(id text,guard text,fee_note text,fee_source_text text,parking_zones jsonb);
create temporary table strip_fee_o(id text,guard text,note text);

"""

FEE_TAIL = """
-- 同 202611020100：只改費率文字，不順帶依分區重算停車資格旗標。
alter table public.community_spots disable trigger community_spots_flags_from_entries;
alter table public.official_heavy_spots disable trigger official_heavy_spots_flags_from_entries;

do $$
declare v_c integer; v_o integer;
begin
  -- 沒有這批資料的資料庫不做任何更新，也不推進 data_versions。
  if not exists(select 1 from public.community_spots c join pg_temp.strip_fee_c s on c.id=s.id::uuid)
     and not exists(select 1 from public.official_heavy_spots o join pg_temp.strip_fee_o s on o.id=s.id::uuid) then
    return;
  end if;
  update public.community_spots c
    set fee_note=s.fee_note,fee_source_text=s.fee_source_text,parking_zones=s.parking_zones
    from pg_temp.strip_fee_c s
    where c.id=s.id::uuid and c.source='import'
      and md5(concat_ws(chr(31),coalesce(c.fee_note,''),coalesce(c.fee_source_text,''),
        coalesce(c.parking_zones,'[]'::jsonb)::text))=s.guard;
  get diagnostics v_c=row_count;
  update public.official_heavy_spots o set note=s.note
    from pg_temp.strip_fee_o s
    where o.id=s.id::uuid and md5(coalesce(o.note,''))=s.guard;
  get diagnostics v_o=row_count;
  if v_c+v_o>0 then
    insert into public.admin_audit_log(actor,action,target_table,target_id,before,after,note)
    values('00000000-0000-0000-0000-0000000000de','strip_copied_fee_text','spots','275',null,
      jsonb_build_object('community_spots',v_c,'official_heavy_spots',v_o,
        'fields',jsonb_build_array('fee_note','fee_source_text','parking_zones.fee_note','note')),
      '我的地圖費率片段清除，只留固定詞彙（#275）');
  end if;
end $$;

alter table public.community_spots enable trigger community_spots_flags_from_entries;
alter table public.official_heavy_spots enable trigger official_heavy_spots_flags_from_entries;
drop table pg_temp.strip_fee_c;
drop table pg_temp.strip_fee_o;
"""


def insert(table, columns, rows, select="v.*", prefix=""):
    if not rows:
        return f"-- {table}: 0\n"
    return (f"-- {table}: {len(rows)}\ninsert into pg_temp.{table}({columns}) select {prefix}{select} from (values\n"
            + ",\n".join(rows) + "\n) v;\n")


def migration(backup, layer):
    community, official, edited = load(backup)
    listed = edited_list(community, official, edited, layer)
    lines = "\n".join(f"--   {table} {spot_id} {field}" for table, spot_id, field, _ in listed) or "--   （無）"
    if layer == "text":
        (_, rows_c), (_, rows_o) = text_sql(community, official, edited)
        columns = "tbl,id,guard,note,entrance_note,parking_guide,special_rules"
        return (TEXT_HEAD.format(edited=lines) + insert("strip_text", columns, rows_c, prefix="'c',")
                + insert("strip_text", columns, rows_o, prefix="'o',") + TEXT_TAIL)
    rows_c, rows_o = fee_sql(community, official, edited)
    return (FEE_HEAD.format(edited=lines)
            + insert("strip_fee_c", "id,guard,fee_note,fee_source_text,parking_zones", rows_c,
                     select="v.column1,v.column2,v.column3,v.column4,v.column5::jsonb")
            + insert("strip_fee_o", "id,guard,note", rows_o) + FEE_TAIL)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backup", type=Path, required=True, help="directory of the read-only dump (not in the repo)")
    parser.add_argument("--layer", choices=("text", "fee"), required=True)
    parser.add_argument("--list-edited", action="store_true", help="print the administrator-edited spots instead")
    parser.add_argument("--output", type=Path, help="migration file to write")
    args = parser.parse_args()
    if args.list_edited:
        community, official, edited = load(args.backup)
        for row in edited_list(community, official, edited, args.layer):
            print("\t".join(row))
        return
    args.output.write_text(migration(args.backup, args.layer))
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
