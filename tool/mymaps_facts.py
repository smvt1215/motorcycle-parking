"""Only verified facts from the My Maps compilation, in our own fixed words (#275).

The source map's descriptions are its author's and contributors' writing, so
none of it is stored as written. A line that states a fact found in the
vocabulary below becomes that fact's fixed phrase; every other line is
dropped. Numbers (bay counts, minutes, floors) are facts and are kept.

`import_mymaps.py` builds spots with these phrases, and `scrub_spot()` applies
the same rules to spots imported before (the repo JSON and, through a
generated migration, the database), so both end in the same words.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

COMMUNITY = "社群補充（未經官方查核）："
LICENSE = "社群協力資料，經核驗後只收錄事實"
OPEN_DATA = "政府資料開放授權條款第 1 版"
OFFICIAL_LICENSE = f"{OPEN_DATA}；{LICENSE}"

CN = {"一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10}
N = r"(\d+|[一二兩三四五六七八九十])"


def number(text):
    return int(text) if text.isdigit() else CN[text]


def heavy_bays(line):
    """`有六格重機專用格`, `專用2格以上`, `B2 重機專用5格` → 重機專用格 N 格（以上）."""
    match = (re.search(rf"{N}\s*(?:個|格|席)(?:以上)?\s*(?:大型)?(?:(?:重機|大重|重型機車)(?:專用|專屬)?|專用|專屬)(?:格|車?位)", line)
             or re.search(rf"(?:重機|大重|專用)(?:專用|專屬)?(?:停車)?(?:格|車?位)?\s*(?:共)?\s*{N}\s*(?:個|格|席)", line)
             or re.search(rf"(?:重機|大重|專用)(?:專用|專屬)?(?:停車)?(?:格|車?位)\s*\*\s*(\d+)", line)
             or re.search(rf"{N}\s*(?:席|個)?\s*大型重型機車(?:停車)?位", line)
             or re.search(rf"大型重型機車(?:停車)?位\s*{N}\s*席", line))
    if not match:
        return ""
    more = "以上" if re.search(r"以上|或以上|[>＞]", line[match.start():match.end() + 4]) else ""
    return f"重機專用格 {number(match[1])} 格{more}"


def first_minutes_free(line):
    match = re.search(r"(?:前|首)?\s*(半小時|\d+\s*分鐘)(?:內)?(?:離場)?\s*免費", line)
    if not match:
        return ""
    minutes = 30 if match[1] == "半小時" else int(re.sub(r"\D", "", match[1]))
    return f"前 {minutes} 分鐘免費"


def floor(line):
    match = re.search(r"(?<![A-Za-z])([BbＢ])\s*(\d)(?!\d)", line)
    if not match or not re.search(r"重機|大重|專用", line):
        return ""
    return f"重機停放樓層：B{match[2]}"


# (field, pattern or function, phrase). In one group only the first match counts,
# so a negation (無後牌辨識) is tried before the plain fact (後牌辨識).
FACTS = [
    ("plate", [
        ("entrance_note", r"(僅|只)有?前(車)?[牌排]", "只辨識前車牌"),
        ("entrance_note", r"(無|沒有)(後方|後車?[牌排])", "無後車牌辨識"),
        ("entrance_note", r"後(車)?[牌排]|後方辨識", "後車牌辨識"),
        ("entrance_note", r"前(車)?[牌排]", "前車牌辨識"),
    ]),
    ("ticket", [("entrance_note", r"按鈕(取|按)?票|取票|按鈕入場", "按鈕取票")]),
    ("staff", [("entrance_note", r"^管理員$|按鈴|對講機|管理(員|人員).{0,3}(協助|開門|開閘|引導|登記|給票|指示|抄車牌)|請(工作)?人員協助|警衛.{0,2}(協助|引導)|"
                                 r"工作人員引導|專人引導|指揮停", "需按鈴或請管理員協助")]),
    ("card", [("entrance_note", r"悠遊卡|電子票證", "悠遊卡進出")]),
    ("keypad", [("entrance_note", r"鍵盤輸入", "鍵盤輸入車號")]),
    ("coin", [("entrance_note", r"代幣|投幣|投十元|取幣", "需投幣或取代幣")]),
    ("reverse", [("entrance_note", r"倒退|倒車", "可能需倒車進場")]),
    ("cash", [("entrance_note", r"人工(收費|繳費)|管(理)?(員)?室繳費|現金繳費|手動開單", "人工繳費")]),
    ("gate", [("entrance_note", r"(無|沒有)(柵欄|閘門|出入口管制)|無管制", "無柵欄")]),
    ("lane", [
        ("entrance_note", r"機車(車)?道.{0,4}禁止|建議不要走機車道", "機車車道禁止或不建議大型重機"),
        ("entrance_note", r"走汽車(車)?道|汽車(車)?道.{0,3}(入|進|按|取|有)|汽車入口", "走汽車車道"),
        ("entrance_note", r"走機車(車)?道|機車(車)?道.{0,3}(入|進|可進|悠遊卡)|機車(出)?入口", "走機車車道"),
    ]),
    ("bays", [
        ("parking_guide", r"(無|沒有)(重機)?專用(格|車?位)|無專用", "無重機專用格"),
        ("parking_guide", heavy_bays, None),
        ("parking_guide", r"專用格|重機格|重機(專用|專屬)(停車)?(區|格位|空間)|重機停車區|重機辨識區|重機區|大重(專用|區)|重機專用|專用空間", "有重機專用格"),
    ]),
    ("car_area", [
        ("parking_guide", r"汽車(區|格|停車場|停車區).{0,3}(禁|不可|不給)", "汽車區禁止大型重機"),
        ("parking_guide", r"可.{0,2}停.{0,3}汽車|停汽車(格|區|位|停車)|汽車格.{0,3}都可停|大台.{0,4}汽車格", "可停汽車格"),
    ]),
    ("scooter_area", [
        ("parking_guide", r"機車(區|格|停車場|停車區).{0,6}(開單|警告|罰)", "停機車格可能被開單"),
        ("parking_guide", r"機車(區|格|停車場|停車區).{0,4}(禁|不可|不給)", "機車區禁止大型重機"),
        ("parking_guide", r"可.{0,2}停.{0,3}機車|停機車(格|區|位|停車)|機車格.{0,3}都可停|機車格汽車格都可停", "可停機車格"),
    ]),
    ("angle", [("parking_guide", r"斜停\s*(兩|2)\s*格", "可斜停兩格")]),
    ("floor", [("parking_guide", floor, None)]),
    ("ban", [
        ("note", r"(沒看到|無|未|沒有)(標示)?.?(禁止|禁停)", "現場未見禁止大型重機標示"),
        ("note", r"禁止.{0,6}(重機|大重)|禁停.{0,2}(大)?重機|不給重機停", "有禁止大型重機停放的回報"),
    ]),
    ("discount", [("note", r"折抵|消費.{0,8}折", "消費可折抵停車費")]),
    ("free_minutes", [("note", first_minutes_free, None)]),
    ("hours", [("note", r"非\s*24\s*[Hh小]", "非 24 小時營業")]),
    ("overnight", [("note", r"不可過夜", "不可過夜停放")]),
    ("lockers", [("note", r"安全帽櫃", "有安全帽置物櫃")]),
    ("narrow", [("note", r"車道.{0,2}窄|窄車道|通道較窄|道路窄", "車道較窄")]),
    ("slope", [("note", r"坡道.{0,4}陡|斜坡|爬坡", "進出有斜坡")]),
    ("turn", [("note", r"直角轉彎|180\s*度?迴轉", "入口轉彎較急")]),
    ("ceiling", [("note", r"天花板.{0,4}低", "天花板較低")]),
    ("few", [("note", r"容易滿|停滿|數量(都)?不多|格子(少|不多)|位置(不多|偏少)", "車位不多")]),
]
FIELDS = ("note", "entrance_note", "parking_guide")


# A line that hedges (不確定是否有重機專用格, 理論上可停) states no fact.
HEDGE = re.compile(r"不確定|不知道|待確認|待踩點|好像|應該|理論上|可能可以|不清楚|[?？]")


def facts(lines):
    """Fixed phrases a source's lines state, by field; everything else in the lines is dropped."""
    found = {field: [] for field in FIELDS}
    for line in lines:
        known = fact_field(line)
        if known:  # already one of ours: scrubbing twice changes nothing
            if line not in found[known]:
                found[known].append(line)
            continue
        if HEDGE.search(line):
            continue
        for _, rules in FACTS:
            for field, rule, phrase in rules:
                text = rule(line) if callable(rule) else (phrase if re.search(rule, line) else "")
                if text:
                    if text not in found[field]:
                        found[field].append(text)
                    break
    # A bay count says more than 有重機專用格.
    if any(re.fullmatch(r"重機專用格 \d+ 格(以上)?", f) for f in found["parking_guide"]):
        found["parking_guide"] = [f for f in found["parking_guide"] if f != "有重機專用格"]
    return found


VOCABULARY = {phrase: field for _, rules in FACTS for field, rule, phrase in rules if phrase}
FACT_FORMS = [(re.compile(p), field) for p, field in ((r"重機專用格 \d+ 格(以上)?", "parking_guide"),
                                                      (r"前 \d+ 分鐘免費", "note"), (r"重機停放樓層：B\d", "parking_guide"))]


def fact_field(text):
    """The field a vocabulary phrase belongs to, or "" when the text is not one."""
    return VOCABULARY.get(text) or next((field for form, field in FACT_FORMS if form.fullmatch(text)), "")


def is_fact(text):
    return bool(fact_field(text))


# Fee fragments: the source's fee shorthand sometimes carried a note (需按鈴,
# 後牌, B2限悠遊卡); only the entrance facts above survive, as fixed words.
def fee_terms(fragment):
    found = facts([fragment])
    return found["entrance_note"] + found["note"]


# ---- Spots imported before the vocabulary: line by line, as the old tool wrote them.

DIRECTION = re.compile(r"入口方向：(東西向皆可進入|往西方向進入|往東方向進入)")
OLD_DIRECTION = re.compile(r"來源標示：(東西向皆可進入|往西方向進入|往東方向進入)（[⇦⇨]+）")
COLOR_NOTE = re.compile(r"來源標示(為未確認資訊|進出場需注意（.*）|為特殊收費或管理方式)")
MATCHED = re.compile(r"已比對.+（[^（）]+）")
TIMED = re.compile(r"限時開放：.+")
BANNED = "來源回報禁止大型重機停放"
PILOT = re.compile(r"臺北市路外停車場試辦大型重機停放機車區.*")
SUMMARY = re.compile(r"社群補充（未經官方查核）：(.*)")
ROADSIDE_FEE = "大型重機依路段收費方式："
STANDARD_FEE = re.compile(
    r"(平日|假日|黃牌|紅牌|限假日|日間|夜間|機車區|汽車區|展期|無展期|室內|室外|機車|汽車|重機)?"
    r"(每 \d+ 小時|每小時|每日|隔夜|每半天|每月|每次) \d+ 元|免費 \d+ 小時|免費|請依現場公告")
TEMPLATE = {
    "note": (MATCHED,),
    "entrance_note": (DIRECTION,),
    "parking_guide": (),
    "special_rules": (TIMED, re.compile(BANNED), PILOT),
}


def split_lines(value):
    return [line.strip() for line in (value or "").split("\n") if line.strip()]


def kept_template(field, line):
    return any(pattern.fullmatch(line) for pattern in TEMPLATE[field])


def scrub_fee_text(text):
    """A parse_fee() sentence: standard price parts stay, a fragment keeps only its fixed words.

    Fee sentences the database wrote from a structured fee (fee_note_of) are not
    parse_fee output; callers leave those alone."""
    if (text or "").startswith(ROADSIDE_FEE):
        return text  # the tool's own Taipei roadside sentence, from the city's announcement
    basis = re.search(r"（(大型重機|重機專用格)[^（）]*）$", text or "")
    body = (text or "")[:basis.start()] if basis else (text or "")
    parts = []
    for raw in body.split("；"):
        raw = raw.strip()
        price = STANDARD_FEE.match(raw)
        for part in ([price[0]] if price else []) + fee_terms(raw[price.end():] if price else raw):
            if part not in parts:
                parts.append(part)
    sentence = "；".join(parts) or "請依現場公告"
    return sentence + (basis[0] if basis else "")


def special_rules(value):
    lines = []
    for line in split_lines(value):
        if kept_template("special_rules", line):
            lines.append(line)
        else:
            # A timed shared bay's window: `20/d - 平日夜間18-8 / 假日限定` → 限時開放：平日夜間18-8 / 假日限定.
            timed = re.fullmatch(r"\S+\s+-\s+((?:平日|假日|夜間|日間).+)", line)
            if timed:
                lines.append(f"限時開放：{timed[1]}")
    return "\n".join(lines)


def scrub_spot(spot, official):
    """New note, entrance_note, parking_guide and special_rules of a spot the old tool wrote."""
    copied, kept = [], {field: [] for field in (*FIELDS, "special_rules")}
    summary = None
    for field in FIELDS:
        for line in split_lines(spot.get(field)):
            if line == COMMUNITY.rstrip() or line == COMMUNITY:
                continue
            if official and field == "note" and SUMMARY.fullmatch(line) and summary is None:
                summary = SUMMARY.fullmatch(line)[1]
            elif COLOR_NOTE.fullmatch(line) or line.startswith("來源原名稱："):
                continue
            elif field == "entrance_note" and OLD_DIRECTION.fullmatch(line):
                kept[field].append(f"入口方向：{OLD_DIRECTION.fullmatch(line)[1]}")
            elif kept_template(field, line):
                kept[field].append(line)
            else:
                copied.append(line)
    found = facts(copied)
    out = {"special_rules": special_rules(spot.get("special_rules"))}
    for field in ("entrance_note", "parking_guide"):
        lines = kept[field] + [f for f in found[field] if f not in kept[field]]
        out[field] = "\n".join(([COMMUNITY] if official and lines else []) + lines)
    if official:
        claims = "；".join(filter(None, [summary, *found["note"]]))
        out["note"] = "\n".join(filter(None, [claims and COMMUNITY + claims, *kept["note"]]))
    else:
        out["note"] = "\n".join(found["note"] + kept["note"])
    return out


def scrub_summary_fees(note):
    """An official note's community summary lists areas with their parse_fee() fees in parentheses."""
    def area(match):
        return f"（{scrub_fee_text(match[1])}）"
    lines = []
    for line in split_lines(note):
        if line.startswith(COMMUNITY):
            # 停放區域：汽車區（每小時 30 元；倒退掃牌）、機車區（…）— fee parentheses hold ； too.
            line = COMMUNITY + re.sub(r"（([^（）]*)）", area, line[len(COMMUNITY):])
        lines.append(line)
    return "\n".join(lines)


def license_note(value, official):
    if not official:
        return LICENSE
    return OFFICIAL_LICENSE if "Alan" in (value or "") else OPEN_DATA


# ---- CLI: rewrite the committed JSON.

def rewrite_file(path, official):
    spots = json.loads(Path(path).read_text())
    for spot in spots:
        if official and "Alan" not in spot.get("license_note", ""):
            continue
        new = scrub_spot(spot, official)
        if official:
            new["note"] = scrub_summary_fees(new["note"])
        else:
            spot["fee_note"] = scrub_fee_text(spot["fee_note"])
            for zone in spot.get("parking_zones", []):
                if "fee_note" in zone:
                    zone["fee_note"] = scrub_fee_text(zone["fee_note"])
        for key, value in new.items():
            if value:
                spot[key] = value
            elif key in spot and key != "note":
                del spot[key]
            elif key == "note":
                spot["note"] = ""
        spot["license_note"] = license_note(spot.get("license_note"), official)
    Path(path).write_text(json.dumps(spots, ensure_ascii=False, indent=2) + "\n")
    return len(spots)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--community", type=Path, default=Path("data/imports/google-mymaps/spots.json"))
    parser.add_argument("--official", type=Path, default=Path("data/imports/official/spots.json"))
    args = parser.parse_args()
    print(rewrite_file(args.community, False), "community;", rewrite_file(args.official, True), "official")


if __name__ == "__main__":
    main()
