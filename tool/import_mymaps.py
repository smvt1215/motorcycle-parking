"""Normalize a Google My Maps KML export into project spots, checked against official open data.

Pipeline: KML placemarks → layer/icon mapping → NLSC city/district lookup →
Taipei/New Taipei off-street lot matching → `ParkingSpot` JSON + review report.
Every imported spot stays `pending`; the report lists each official correction.

The only database path is the Admin Web import page (docs/ADMIN_WEB.md, P6),
which reads the spots.json files written here and keeps what an administrator
changed. The SQL output (import.sql / official.sql) is gone: its official
upsert overwrote every column but `hidden` and `effective_date`, so each rerun
undid administrators' edits (#117).
"""
import argparse
import csv
from datetime import date
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

KML_URL = "https://www.google.com/maps/d/kml?mid={mid}&forcekml=1"
VIEWER_URL = "https://www.google.com/maps/d/viewer?mid={mid}"
NLSC_URL = "https://api.nlsc.gov.tw/other/TownVillagePointQuery/{lng}/{lat}/4326"
OFFICIAL = {
    "臺北市": ("臺北市停車場資訊（臺北市停車管理工程處）", "https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_alldesc.json"),
    "新北市": ("新北市路外公共停車場資訊（新北市政府交通局）", "https://data.ntpc.gov.tw/api/datasets/B1464EF0-9C7C-4A6F-ABF7-6BDF32847E68/json?page={page}&size=1000"),
    "臺中市": ("臺中市路外剩餘車位（臺中市政府交通局）", "https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=4f9c4d26-d826-4277-8f8a-6d2469fe9653"),
    "桃園市": ("桃園市停車率（路外、路邊）", "https://opendata.tycg.gov.tw/api/dataset/d8a0dbc5-42fc-49ba-a280-1700ff78427a/resource/552ed03e-8daf-4b5f-8c6a-b466d378833b/download"),
    "高雄市": ("高雄市公有／民營路外停車場一覽表（高雄市政府交通局）", "https://openapi.kcg.gov.tw/Api/Service/Get/30c58c88-4f53-45a0-8393-e655feaaa65b"),
    "臺南市": ("臺南市路外停車場動態資訊（臺南市政府交通局）", "https://parkweb.tainan.gov.tw/api/parking.php?mode=0"),
    "新竹市": ("新竹市公有停車場相關資訊（新竹市政府交通處）", "https://odws.hccg.gov.tw/001/Upload/25/opendataback/9059/27/385f68c2-95e6-48cd-a9f8-0d3ffa35554b.json"),
}
KAOHSIUNG_PRIVATE = "https://openapi.kcg.gov.tw/Api/Service/Get/aeb8ba3c-8eec-49f6-8768-91218c819909"
# odws.hccg.gov.tw omits its intermediate certificate; fetch it from the
# certificate's AIA URL instead of turning verification off. The AIA URL is
# plain HTTP, so only the pinned certificate (TWCA SSL Certification Authority,
# issued by TWCA CYBER Root CA, valid to 2033-02-23) is ever trusted.
HCCG_INTERMEDIATE = "http://sslserver.twca.com.tw/cacert/Cyber_SSL_2023.crt"
HCCG_INTERMEDIATE_SHA256 = "01af2324d098098f5e0cdf6faabada430b21cce777f47eacb26248b2fda3e531"
NS = "{http://www.opengis.net/kml/2.2}"

# 臺北市停管處公告之路外停車場試辦大重機停放機車區場域（115/4/6 首波 24 處、115/7/6 新增 12 處），
# 摘自兩份新聞稿附件 PDF；機車區費率為各場機車費率 2 倍。
TAIPEI_PILOT_URLS = (
    "https://dot.gov.taipei/News_Content.aspx?n=D739A9F6B5C0AB95&sms=72544237BBE4C5F6&s=A65BDD5E3B218D8D",
    "https://pma.gov.taipei/News_Content.aspx?n=C367863C93700356&s=303CA11AE786D9FC",
)
PER_HOUR_60, PER_HOUR_40, PER_HOUR_100, PER_ENTRY = "計時20元（當日當次上限60元）", "計時20元（當日當次上限40元）", "計時20元（當日當次上限100元）", "計次40元，隔日另計"
TAIPEI_PILOT = {
    "捷運士林站橋下機車停車場": PER_HOUR_60, "捷運劍潭站橋下機車停車場": PER_HOUR_60, "平陽街機車臨時平面停車場": PER_HOUR_60,
    "建成國中地下停車場": PER_HOUR_60, "龍門國中地下停車場": PER_ENTRY, "嘉興公園地下停車場": PER_ENTRY,
    "濱江國中地下停車場": PER_HOUR_40, "永盛公園地下停車場": PER_ENTRY, "行一機車臨時平面停車場": PER_HOUR_100,
    "行善社會住宅地下停車場": PER_HOUR_40, "東湖國小地下停車場": PER_ENTRY, "樂活公園地下停車場": PER_HOUR_40,
    "景美女中地下停車場": PER_HOUR_40, "景美國小地下停車場": PER_HOUR_40, "福星公園地下停車場": PER_HOUR_40,
    "振興公園地下停車場": PER_HOUR_40, "八德立體停車場": PER_HOUR_40, "松山國小地下停車場": PER_ENTRY,
    "廣慈衛福大樓地下停車場": PER_HOUR_40, "信義廣場地下停車場": PER_ENTRY, "世貿公園地下停車場": PER_ENTRY,
    "玉成國小地下停車場": PER_HOUR_40, "青年二期社會住宅地下停車場": PER_HOUR_40, "艋舺公園地下停車場": PER_HOUR_40,
    "福林公園地下停車場": PER_ENTRY, "啟聰學校地下停車場": PER_ENTRY, "大安森林公園地下停車場": PER_HOUR_40,
    "長安國小地下停車場": PER_HOUR_40, "萬興國小地下停車場": PER_ENTRY, "七星公園地下停車場": PER_HOUR_40,
    "民有市場地下停車場": PER_HOUR_40, "松山工農地下停車場": PER_HOUR_40, "忠信地下停車場": PER_HOUR_40,
    "玉成公園地下停車場": PER_ENTRY, "南港機廠1區社會住宅地下停車場": PER_ENTRY, "青年公園高爾夫球場地下停車場": PER_ENTRY,
}
PILOT_RULES = "臺北市路外停車場試辦大型重機停放機車區（各期 6 個月）：依現場標誌斜停，最多 2 格機車格；停汽車區依小型車費率。試辦是否延續請以現場公告為準"
# 115/10/6 起臺北市公有路邊收費機車格全面開放大型重機停放；費率依路段收費方式而不同。
TAIPEI_ROADSIDE = ("大型重機依路段收費方式：計次每次 40 元；計時每小時 20 元、當日上限 100 元；限時格首 20 分鐘 0 元"
                   "（臺北市 115/10/6 起，可斜停 2 格）",
                   "https://www.gov.taipei/News_Content.aspx?n=D0042A87C2F0270A&s=1190C312983454BA&sms=78D644F2755ACCAA")
COMMUNITY_SOURCE = "社群回報整理"
# Press-release boilerplate copied into descriptions; the structured fields above replace it.
BOILERPLATE = re.compile(r"停管處|以下簡稱|試辦期程|^停放於(汽車|機車)區")

# My Maps icon ids used by the source map: which bay a placemark describes.
ZONE_BY_ICON = {"1538": ("汽車區", "heavyCar"), "1632": ("機車區", "scooterHeavy"), "1633": ("重機專用格", "heavyOnly")}
# Icon colors are the source's legend: unverified, entry caveats, special handling.
COLOR_NOTES = {
    "757575": "來源標示為未確認資訊",
    "E65100": "來源標示進出場需注意（可能無後車牌辨識，需按鈴或請管理員協助）",
    "0288D1": "來源標示為特殊收費或管理方式",
}
# Layer → fee basis wording; layers absent here are not parking points.
FEE_BASIS = {
    "汽車費率": "大型重機比照汽車費率",
    "免費汽車停車場": "大型重機停汽車區",
    "重機格/汽車費率": "重機專用格比照汽車費率",
    "重機格/個別費率": "大型重機另訂費率",
    "機車費率": "大型重機比照機車費率",
    "未確定": "",
    "禁停重機": "",
    "路邊友善車格": "",
}
CREDIT = re.compile(r"(感謝|謝謝).*|.*(@ptt|@PTT).*|.*熱心回報.*|.*網友.*(回報|分享).*")
URL = re.compile(r"https?://\S+")
ENTRY = re.compile(r"入場|出場|進場|離場|辨識|辨析|按鈴|按鈕|取票|柵欄|閘門|車道|入口|出入口|倒退嚕|管理員")
# Where to put the bike once inside: floors, areas, bay types, how to fit the bays.
GUIDE = re.compile(r"停(放|在|於)|專用格|重機格|重機區|機車區|汽車區|汽車格|機車格|[BbＢ]\d|\d\s*[FＦ樓]|斜停|跨.?格|格線")
# A retail brand only the official name carries means another business's lot.
RETAIL = re.compile(r"(?i)全聯|家樂福|家福|好市多|costco|大潤發|愛買|ikea|宜家|麥當勞|新光三越|遠東百貨|sogo|微風")
RETAIL_ALIAS = {"家福": "家樂福", "costco": "好市多", "宜家": "ikea"}


def retail(name):
    return {RETAIL_ALIAS.get(brand.lower(), brand.lower()) for brand in RETAIL.findall(name)}


# Parking operators. A name without one may still be an operator's lot, but two
# different operators mean two facilities (城市車旅士林福德一站 is not Times士林福德路第3).
OPERATOR = re.compile(r"(?i)嘟嘟房|city ?parking|城市車旅|times|168 ?parking|168停車聯盟|正好停|俥亭|uspace|台灣聯通|富山停車|歐特儀|"
                      r"康達盛通|吉拾|日月亭|辰淵|utaggo")
OPERATOR_ALIAS = {"city parking": "城市車旅", "cityparking": "城市車旅", "168parking": "168", "168 parking": "168", "168停車聯盟": "168"}


def operators(name):
    return {OPERATOR_ALIAS.get(found.lower(), found.lower()) for found in OPERATOR.findall(name)}


# Operator brands and parking words say nothing about which lot a name means.
GENERIC = re.compile(
    r"(?i)嘟嘟房|city ?parking|城市車旅|times|168 ?parking|168停車聯盟|正好停|俥亭|uspace|台灣聯通|富山停車|歐特儀|康達盛通|吉拾|"
    r"[臺新][北中南東]市|桃園市|高雄市|基隆市|新竹[市縣]|嘉義[市縣]|苗栗縣|彰化縣|南投縣|雲林縣|屏東縣|宜蘭縣|花蓮縣|臺東縣|澎湖縣|金門縣|連江縣|"
    r"停車場|停車|地下|立體|平面|公有|附設|機車|汽車|重機|專用|大樓|股份有限公司|市立|[東西南北]側|[區店站格]|"
    r"[()（）\s\-‧・·|｜/、,，.。:&⇦\[\]]"
)


def fetch(url, path, refresh=False, context=None):
    if refresh or not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url, timeout=60, context=context) as response:
            path.write_bytes(response.read())
    return path


def hccg_context(cache, refresh=False):
    der = fetch(HCCG_INTERMEDIATE, cache / "twca_ssl_2023.crt", refresh).read_bytes()
    if hashlib.sha256(der).hexdigest() != HCCG_INTERMEDIATE_SHA256:
        raise ValueError("TWCA intermediate certificate does not match the pinned fingerprint")
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=der)
    return context


def clean_text(value):
    """KML HTML descriptions → plain lines without links, images or personal credits."""
    value = re.sub(r"<img[^>]*>", "", value or "")
    value = re.sub(r"<br\s*/?>", "\n", value)
    value = html.unescape(re.sub(r"<[^>]+>", "", value))
    lines = []
    for line in value.splitlines():
        line = re.sub(r"\s+", " ", URL.sub("", line).replace("\t", " ")).strip(" -")
        if line and not CREDIT.fullmatch(line) and not BOILERPLATE.search(line) and not re.fullmatch(r"[-=*_ ]+", line):
            lines.append(line)
    return lines


def parse_fee(text):
    """`(平50/h|假60/h)` → 平日每小時 50 元；假日每小時 60 元."""
    if not re.search(r"\d|(?i:free)", text or ""):
        return "請依現場公告"
    prefixes = {"平": "平日", "假": "假日", "黃": "黃牌", "紅": "紅牌", "假日限定": "限假日", "日": "日間", "夜": "夜間",
                "機": "機車區", "汽": "汽車區", "展期": "展期", "無展": "無展期"}
    parts = []
    text = re.sub(r"(\d)\s*\|\s*d\b", r"\1/d", text.strip()).replace("管理員", "需管理員協助").replace("按鈴", "需按鈴")
    for raw in re.split(r"\s*[|｜;；]\s*|\s+-\s+|(?<=\d):(?=\D)", text):
        # A short label (平, 黃, 室內, 機車…) may precede the amount; known abbreviations are expanded.
        match = re.fullmatch(r"([^\d:：/]{0,4}?)\s*[:：]?\s*(\d+)\s*/?\s*(\d*)\s*([hHdD]|次|隔夜|半天|月)?(.*)", raw)
        # A number counts as a price only with a unit, or alone after a known prefix (平40);
        # otherwise digits are part of a note (B2限悠遊卡, 後牌停5/F) and the text stays as written.
        priced = match and (match[4] or (not match[5].strip(" :") and match[1].strip() in ("", *prefixes)))
        if priced:
            hours = f"每 {match[3]} 小時" if match[3] else "每小時"
            unit = {"h": hours, "d": "每日", "隔夜": "隔夜", "半天": "每半天", "月": "每月"}.get((match[4] or "").lower(), "每次")
            label = match[1].strip()
            parts.append(f"{prefixes.get(label, label)}{unit} {match[2]} 元{match[5].strip(' :')}")
        elif raw:
            parts.append(re.sub(r"(?i)free", "免費", re.sub(r"(?i)free\s*/\s*(\d+)h", r"免費 \1 小時", raw)))
    return "；".join(parts) or "請依現場公告"


ARROWS = {"⇦⇨": "東西向皆可進入", "⇦": "往西方向進入", "⇨": "往東方向進入"}


def entry_direction(name):
    """Leading ⇦/⇨ markers give the lane an entrance is reached from; returns (name without them, note)."""
    match = re.match(r"\s*([⇦⇨]+)\s*(.*)", name)
    if not match:
        return name, ""
    return match[2], f"來源標示：{ARROWS.get(match[1], match[1])}（{match[1]}）"


def split_name(name):
    """Leading `(fee)` prefix carries the fee; `(禁止)` carries no fee."""
    match = re.match(r"\s*[(（]([^)）]*)[)）]\s*(.*)", name)
    if not match:
        return name.strip(), ""
    return match[2].strip(), "" if match[1] == "禁止" else match[1]


def placemarks(path):
    root = ET.parse(path).getroot()
    for folder in root.iter(NS + "Folder"):
        layer = folder.findtext(NS + "name")
        for mark in folder.findall(NS + "Placemark"):
            # Point styles are `#icon-<icon>-<color>…`, line styles `#line-<color>-<width>…`.
            style = re.match(r"#icon-(\d+)-([0-9A-F]{6})|#(line)-([0-9A-F]{6})", mark.findtext(NS + "styleUrl") or "")
            coords = mark.find(f".//{NS}coordinates")
            if coords is None:
                continue
            points = [tuple(map(float, c.split(",")[:2])) for c in (coords.text or "").split()]
            yield {
                "layer": layer, "name": mark.findtext(NS + "name") or "", "description": mark.findtext(NS + "description") or "",
                "icon": style and (style[1] or style[3]) or "", "color": style and (style[2] or style[4]) or "",
                "line": mark.find(f".//{NS}LineString") is not None, "points": points,
            }


def midpoint(points):
    """(lng, lat) halfway along a polyline's length; a single point is itself."""
    lengths = [distance(a[1], a[0], b[1], b[0]) for a, b in zip(points, points[1:])]
    remaining = sum(lengths) / 2
    for (a, b), length in zip(zip(points, points[1:]), lengths):
        if length and remaining <= length:
            t = remaining / length
            return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        remaining -= length
    return points[0]


def normalize(mark):
    """One placemark → project spot fields (city/district filled later), or None when not a parking point."""
    layer, icon, color = mark["layer"], mark["icon"], mark["color"]
    if layer not in FEE_BASIS or icon == "1502":
        return None  # shops, and district-level policy notes that belong to city rules
    bare, direction = entry_direction(mark["name"])
    name, fee_text = split_name(bare)
    lines = clean_text(mark["description"])
    lng, lat = midpoint(mark["points"])
    spot = {
        "name": name, "lat": round(lat, 7), "lng": round(lng, 7), "source": "import", "status": "pending",
        "fee_note": parse_fee(fee_text), "heavy_allowed": True, "scooter_allowed": None,
        "scooter_total": None, "available": None, "note": "", "address": "", "road_segment": "",
        "entrance_note": "", "parking_guide": "", "special_rules": "", "parking_zones": [],
    }
    entries = [line for line in lines if ENTRY.search(line)]
    # Long lines are policy paragraphs, not on-site directions.
    guides = [line for line in lines if line not in entries and GUIDE.search(line) and len(line) <= 60]
    others = [line for line in lines if line not in entries + guides]
    spot["parking_guide"] = "\n".join(guides)
    if layer == "路邊友善車格":
        spot["facility_type"] = "roadside"
        if mark["line"]:
            spot.update(space_type="paidMotorcycle", parking_access="scooterHeavy", scooter_allowed=True,
                        road_segment=name, name=f"{re.split(r'[(（]', name)[0]} 普大共用機車格")
        elif color == "9C27B0":
            spot.update(space_type="car", scooter_allowed=True, special_rules=fee_text.replace("Free - ", "限時開放：").replace("Free", "免費"))
            spot["fee_note"] = "免費"
        elif "重機專用" in name:
            spot.update(space_type="heavyOnly", parking_access="heavyOnly", scooter_allowed=False)
        else:
            spot.update(space_type="paidMotorcycle", parking_access="scooterHeavy", scooter_allowed=True)
            road = re.match(r"(?:\S+區)?\s*(\S+?)（(.側)），停車格在(.+?)[。，]", "".join(others))
            if road:
                spot.update(name=f"{road[1]} 普大共用機車格", road_segment=f"{road[1]}（{road[2]}）{road[3]}")
            elif name != "普通大型共用機車格" and re.search(r"[路街巷段]", name):
                spot.update(road_segment=name, name=f"{re.split(r'[(（]', name)[0]} 普大共用機車格")
        spot["note"] = "\n".join(entries + others)
    else:
        spot.update(space_type="offStreet", facility_type=facility_type(name))
        if layer == "禁停重機" or icon == "1898":
            spot.update(heavy_allowed=False, special_rules="來源回報禁止大型重機停放")
        elif layer == "未確定":
            spot.update(heavy_allowed=None)
            spot["parking_zones"] = [{"name": ZONE_BY_ICON.get(icon, ("停放區域",))[0], "fee_note": spot["fee_note"]}]
        else:
            zone, access = ZONE_BY_ICON.get(icon, ("停放區域", None))
            spot["parking_zones"] = [{"name": zone, **({"access": access} if access else {}), "fee_note": spot["fee_note"]}]
            if FEE_BASIS[layer]:
                spot["fee_note"] = f"{spot['fee_note']}（{FEE_BASIS[layer]}）"
        spot["entrance_note"] = "\n".join(filter(None, [direction, *entries]))
        spot["note"] = "\n".join(others)
    # The source's own grey icons and 未確定 layer mark facts it has not confirmed.
    spot["unconfirmed"] = color == "757575" or layer == "未確定"
    caveat = COLOR_NOTES.get(color)
    if caveat:
        key = "entrance_note" if color == "E65100" else "note"
        spot[key] = "\n".join(filter(None, [caveat, spot[key]]))
    return spot


def tm2_to_wgs84(x, y):
    """TWD97 TM2 (121°E zone) → WGS84 lat/lng; GRS80 and WGS84 differ by centimetres."""
    a, f, k0, lng0, dx = 6378137.0, 1 / 298.257222101, 0.9999, math.radians(121), 250000
    e2 = f * (2 - f)
    ep2 = e2 / (1 - e2)
    m = y / k0
    mu = m / (a * (1 - e2 / 4 - 3 * e2 ** 2 / 64 - 5 * e2 ** 3 / 256))
    e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2))
    phi1 = mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * math.sin(2 * mu) + (21 * e1 ** 2 / 16 - 55 * e1 ** 4 / 32) * math.sin(4 * mu) \
        + 151 * e1 ** 3 / 96 * math.sin(6 * mu) + 1097 * e1 ** 4 / 512 * math.sin(8 * mu)
    c1, t1 = ep2 * math.cos(phi1) ** 2, math.tan(phi1) ** 2
    n1 = a / math.sqrt(1 - e2 * math.sin(phi1) ** 2)
    r1 = a * (1 - e2) / (1 - e2 * math.sin(phi1) ** 2) ** 1.5
    d = (x - dx) / (n1 * k0)
    lat = phi1 - n1 * math.tan(phi1) / r1 * (d ** 2 / 2 - (5 + 3 * t1 + 10 * c1 - 4 * c1 ** 2 - 9 * ep2) * d ** 4 / 24
                                             + (61 + 90 * t1 + 298 * c1 + 45 * t1 ** 2 - 252 * ep2 - 3 * c1 ** 2) * d ** 6 / 720)
    lng = lng0 + (d - (1 + 2 * t1 + c1) * d ** 3 / 6 + (5 - 2 * c1 + 28 * t1 - 3 * c1 ** 2 + 8 * ep2 + 24 * t1 ** 2) * d ** 5 / 120) / math.cos(phi1)
    return math.degrees(lat), math.degrees(lng)


def distance(a_lat, a_lng, b_lat, b_lng):
    dy = (a_lat - b_lat) * 111_195
    dx = (a_lng - b_lng) * 111_195 * math.cos(math.radians(a_lat))
    return math.hypot(dx, dy)


def core(name):
    """The part of a lot name that identifies it."""
    return GENERIC.sub("", name.replace("台", "臺").replace("國民中學", "國中").replace("國民小學", "國小"))


def dice(a, b):
    """Dice coefficient on character bigrams."""
    x, y = ({v[i:i + 2] for i in range(len(v) - 1)} or {v} for v in (a.replace("台", "臺"), b.replace("台", "臺")))
    return 2 * len(x & y) / (len(x) + len(y)) if a and b else 0.0


def similarity(a, b):
    """Dice coefficient of the name cores."""
    return dice(core(a), core(b))


def facility_type(text):
    for pattern, kind in (("地下", "underground"), ("立體|停車塔|大樓|建築", "multiStorey"), ("平面|橋下|露天", "surface")):
        if re.search(pattern, text):
            return kind
    return None


def lot(id, name, lat, lng, address="", fee="", summary="", motor=0, heavy=0, district=""):
    """Lots without coordinates (lat None) can only be matched by name within their district."""
    return {"id": id, "name": re.sub(r"\s+", "", name), "lat": float(lat) if lat else None, "lng": float(lng) if lng else None,
            "address": address.strip(), "fee": fee.strip(), "summary": summary, "motor": int(motor or 0),
            "heavy": int(heavy or 0), "district": district}


def number(value):
    return value if str(value).isdigit() else 0


def taipei(cache, refresh):
    rows = json.loads(fetch(OFFICIAL["臺北市"][1], cache / "tpe_alldesc.json", refresh).read_text(encoding="utf-8-sig"))
    return [lot(r["id"], r["name"], *tm2_to_wgs84(float(r["tw97x"]), float(r["tw97y"])), r["address"], r["payex"],
                r["summary"], r["totalmotor"], r.get("totallargemotor")) for r in rows["data"]["park"]]


def new_taipei(cache, refresh):
    lots, page = [], 0
    while True:
        rows = json.loads(fetch(OFFICIAL["新北市"][1].format(page=page), cache / f"ntpc_{page}.json", refresh).read_text())
        lots += [lot(r["ID"], r["NAME"], *tm2_to_wgs84(float(r["TW97X"]), float(r["TW97Y"])), r["ADDRESS"], r["PAYEX"],
                     r["SUMMARY"], r["TOTALMOTOR"]) for r in rows if r["TW97X"] and r["TW97Y"]]
        if len(rows) < 1000:
            return lots
        page += 1


def taichung_name(position):
    """`西屯區-民營-城市車旅-玉門站P` → 城市車旅 玉門站停車場: only the district and agency segments go, since an
    operator or place (大車河台鐵新烏日-地下P) is part of the name; a trailing `(B1F-6F)` is not split on."""
    base, note = re.fullmatch(r"(.*?)(\([^()]*\))?", position).groups()
    parts = base.split("-")
    name = " ".join(parts[2:]) if len(parts) > 2 and parts[0].endswith("區") else parts[-1]
    return re.sub(r"P$", "停車場", name) + (note or "")


def taichung(cache, refresh):
    """`西屯區-民營-城市車旅-玉門站P`: district, operator class, operator…, lot name with a trailing P."""
    rows = json.loads(fetch(OFFICIAL["臺中市"][1], cache / "txg.json", refresh).read_text(encoding="utf-8-sig"))
    return [lot(f"TXG{r['ID']}", taichung_name(r["Position"]), r["Lat"], r["Lng"],
                motor=number(r["TotalMotor"])) for r in rows if r["Lat"] and r["Lng"]]


def taoyuan(cache, refresh):
    """A rolling occupancy log; one row per lot is enough."""
    rows = csv.DictReader(fetch(OFFICIAL["桃園市"][1], cache / "tyc.csv", refresh).read_text(encoding="utf-8-sig").splitlines())
    lots = {}
    for r in rows:
        if r["類別"] == "路外停車" and r["場域名稱"] not in lots:
            name = re.sub(r"[(（](桃交|.{0,6}公司)[)）]$", "", r["場域名稱"])
            lots[r["場域名稱"]] = lot(f"TYC{len(lots) + 1:04d}", name, r["緯度"], r["經度"])
    return list(lots.values())


def kaohsiung(cache, refresh):
    """Rows of `-` are further entrances of the lot above them."""
    rows = json.loads(fetch(OFFICIAL["高雄市"][1], cache / "kcg.json", refresh).read_text())["data"]
    lots, last = [], None
    for n, r in enumerate(rows):
        if r["場名"] != "-":
            last = r
        if last and r["緯度"] not in ("", "-"):
            lots.append(lot(f"KHH{n + 1:04d}", last["場名"] + ("" if "停車場" in last["場名"] else "停車場"), r["緯度"], r["經度"],
                            re.sub(r"^[A-Z]區[:：]", "", r["位置"]), last["收費標準"].replace("-", ""), last["型式"], number(last["機車"])))
    # The private-lot register has no coordinates. Its keys are generic (Column1…);
    # the real field names are the values of a header row, so map by those names.
    rows = json.loads(fetch(KAOHSIUNG_PRIVATE, cache / "kcg_private.json", refresh).read_text())["data"]
    header = next(n for n, r in enumerate(rows) if "停車場名稱" in r.values())
    column = lambda title: next(key for key, value in rows[header].items() if value.startswith(title))
    keys = {title: column(title) for title in ("登記證號", "型式", "停車場名稱", "行政區", "停車場位置", "機車", "收費標準")}
    for r in rows[header + 1:]:
        if r[keys["停車場名稱"]]:
            lots.append(lot(f"KHH-{r[keys['登記證號']]}", r[keys["停車場名稱"]], None, None, r[keys["停車場位置"]],
                            r[keys["收費標準"]], r[keys["型式"]], number(r[keys["機車"]]), district=r[keys["行政區"]]))
    return lots


def tainan(cache, refresh):
    rows = json.loads(fetch(OFFICIAL["臺南市"][1], cache / "tnn.json", refresh).read_text())
    return [lot(r["code"], r["name"], *r["lnglat"].split(","), r["address"], r["chargeFee"], r["typeName"], r["moto_total"])
            for r in rows if str(r["typeId"]) != "4" and "," in (r["lnglat"] or "")]  # 4: roadside concessions


def hsinchu(cache, refresh):
    rows = json.loads(fetch(OFFICIAL["新竹市"][1], cache / "hsz.json", refresh, hccg_context(cache, refresh)).read_text())
    return [lot(f"HSZ{n + 1:03d}", r["停車場名稱"], r["緯度"], r["經度"], r["地址"],
                "；".join(filter(None, [f"平日 {r['平日收費方式']}", f"假日 {r['假日收費方式']}"])).split("充電設備")[0],
                motor=number(r["機車總車位數"])) for n, r in enumerate(rows) if r["緯度"] and r["經度"]]


# Public pages for each official source, linked from official spots (source_url must be https).
SOURCE_PAGES = {
    "臺北市": "https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_alldesc.json",
    "新北市": "https://data.ntpc.gov.tw/datasets/B1464EF0-9C7C-4A6F-ABF7-6BDF32847E68",
    "臺中市": "https://data.gov.tw/dataset/83931",
    "桃園市": "https://data.gov.tw/dataset/173678",
    "高雄市": "https://data.gov.tw/dataset/46944",
    "臺南市": "https://parkweb.tainan.gov.tw/doc/Parkweb_export_API_.pdf",
    "新竹市": "https://data.gov.tw/dataset/67771",
}
TDX_PAGE = "https://tdx.transportdata.tw/"
TDX_TOKEN = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
TDX_API = "https://tdx.transportdata.tw/api/basic/v1/Parking/OffStreet/{kind}/City/{city}?$format=JSON&$top=1000&$skip={skip}"
TDX_INTERVAL = 13  # seconds; TDX allows 5 requests per minute per key
TDX_SOURCE = "TDX 路外停車場（交通部運輸資料流通服務平臺）"
TDX_CITIES = {
    "臺北市": "Taipei", "新北市": "NewTaipei", "桃園市": "Taoyuan", "臺中市": "Taichung", "臺南市": "Tainan", "高雄市": "Kaohsiung",
    "基隆市": "Keelung", "新竹市": "Hsinchu", "新竹縣": "HsinchuCounty", "苗栗縣": "MiaoliCounty", "彰化縣": "ChanghuaCounty",
    "南投縣": "NantouCounty", "雲林縣": "YunlinCounty", "嘉義市": "Chiayi", "嘉義縣": "ChiayiCounty", "屏東縣": "PingtungCounty",
    "宜蘭縣": "YilanCounty", "花蓮縣": "HualienCounty", "臺東縣": "TaitungCounty", "金門縣": "KinmenCounty",
    "澎湖縣": "PenghuCounty", "連江縣": "LienchiangCounty",
}


def tdx_credentials(env_file):
    """Environment first, then the gitignored Edge Function env file; values are never printed."""
    values = {}
    if env_file and env_file.exists():
        for line in env_file.read_text().splitlines():
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"')
    pick = lambda key: os.environ.get(key) or values.get(key)
    return (pick("TDX_CLIENT_ID"), pick("TDX_CLIENT_SECRET")) if pick("TDX_CLIENT_ID") and pick("TDX_CLIENT_SECRET") else None


def tdx_rows(token, kind, city, path, refresh):
    if refresh or not path.exists():
        rows, skip = [], 0
        while True:
            request = urllib.request.Request(TDX_API.format(kind=kind, city=city, skip=skip), headers={"Authorization": f"Bearer {token}"})
            for attempt in range(4):
                time.sleep(TDX_INTERVAL)
                try:
                    with urllib.request.urlopen(request, timeout=60) as response:
                        page = json.loads(response.read())
                    break
                except urllib.error.HTTPError as error:
                    if error.code != 429 or attempt == 3:
                        raise
                    time.sleep(int(error.headers.get("Retry-After") or 60))
            # v1 wraps rows with update metadata: {"UpdateTime": …, "CarParks": [...]}.
            page = page if isinstance(page, list) else next(v for v in page.values() if isinstance(v, list))
            rows += page
            if len(page) < 1000:
                break
            skip += 1000
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(rows, ensure_ascii=False))
    return json.loads(path.read_text())


def tdx_lots(cache, refresh, credentials):
    """Every city's TDX off-street lots and per-city failures; one bearer token covers the whole run."""
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": credentials[0], "client_secret": credentials[1]}).encode()
    with urllib.request.urlopen(urllib.request.Request(TDX_TOKEN, data=body), timeout=30) as response:
        token = json.loads(response.read())["access_token"]
    lots, failed = {}, []
    for name, city in TDX_CITIES.items():
        try:
            parks = tdx_rows(token, "CarPark", city, cache / "tdx" / f"{city}_CarPark.json", refresh)
            spaces = {row["CarParkID"]: row.get("Spaces") or [] for row in
                      tdx_rows(token, "ParkingSpace", city, cache / "tdx" / f"{city}_ParkingSpace.json", refresh)}
        except urllib.error.HTTPError as error:
            failed.append(f"TDX {name}：HTTP {error.code}")  # the URL is safe, but keep reports minimal
            continue
        except (OSError, ValueError, KeyError, StopIteration) as error:  # timeouts, malformed or unexpected JSON
            failed.append(f"TDX {name}：{type(error).__name__}")
            continue
        lots[name] = [
            lot(f"TDX-{row['CarParkID']}", (row.get("CarParkName") or {}).get("Zh_tw", ""),
                (row.get("CarParkPosition") or {}).get("PositionLat"), (row.get("CarParkPosition") or {}).get("PositionLon"),
                row.get("Address") or "", row.get("FareDescription") or "",
                motor=sum(int(s.get("NumberOfSpaces") or 0) for s in spaces.get(row["CarParkID"], []) if int(s.get("SpaceType") or 0) == 2))
            | {"source": TDX_SOURCE, "url": TDX_PAGE}
            for row in parks if (row.get("CarParkPosition") or {}).get("PositionLat")
        ]
    return lots, failed


LOADERS = {"臺北市": taipei, "新北市": new_taipei, "臺中市": taichung, "桃園市": taoyuan, "高雄市": kaohsiung, "臺南市": tainan, "新竹市": hsinchu}


def official_lots(cache, refresh=False, tdx_env=None):
    """City → official lots with WGS84 coordinates; a source that fails is reported, not fatal."""
    lots, failed = {}, []
    for city, load in LOADERS.items():
        try:
            lots[city] = [lot | {"source": OFFICIAL[city][0], "url": SOURCE_PAGES[city]} for lot in load(cache, refresh)]
        except (OSError, ValueError, KeyError, StopIteration) as error:  # StopIteration: a header row not found
            failed.append(f"{city}：{type(error).__name__} {error}".strip())
            lots[city] = []
    credentials = tdx_credentials(tdx_env)
    if not credentials:
        failed.append("TDX：未設定 TDX_CLIENT_ID／TDX_CLIENT_SECRET，略過")
        return lots, failed
    try:
        tdx, tdx_failed = tdx_lots(cache, refresh, credentials)
        failed += tdx_failed
        for city, rows in tdx.items():
            lots.setdefault(city, []).extend(rows)
    except (OSError, ValueError, KeyError) as error:
        failed.append(f"TDX：{type(error).__name__}")  # never echo a request that carried credentials
    return lots, failed


def match_lot(spot, lots):
    """Best official lot: distance alone is not evidence, so closer lots need less name similarity."""
    best = None
    for lot in lots:
        score = similarity(spot["name"], lot["name"])
        if lot["lat"] is None:
            if lot["district"] != spot.get("district") or score < 0.9:
                continue
            meters = None
        else:
            meters = distance(spot["lat"], spot["lng"], lot["lat"], lot["lng"])
            if meters > 600:
                continue
        if retail(lot["name"]) - retail(spot["name"]):
            continue
        ours, theirs = operators(spot["name"]), operators(lot["name"])
        if ours and theirs and not ours & theirs:
            continue
        # A lot named for motorcycles cannot be one the official data lists without any.
        if "機車" in spot["name"] and lot["motor"] == 0 and "機車" not in lot["name"]:
            continue
        # Names that state different structures (地下 vs 平面) are different lots.
        stated = [set(re.findall("地下|立體|平面", name)) for name in (spot["name"], lot["name"])]
        if all(stated) and not stated[0] & stated[1]:
            continue
        # Beyond 200 m only a near-identical name counts: a generic official name
        # (華泰名品城) must not absorb a specific community lot (…機車停車場（三期）).
        if meters is None or (meters <= 80 and score >= 0.45) or (meters <= 200 and score >= 0.6) or score >= 0.95:
            # Equal cores (洲子站, 洲子立體停車場) are told apart by the full names before distance.
            rank = (round(score - (meters or 0) / 1000, 1), dice(spot["name"], lot["name"]), -(meters or 0))
            if best is None or rank > best[0]:
                best = (rank, lot, meters, score)
    return best


def locate(spot, cache_file, cache, attempts=3):
    """[city, district] from NLSC, or None when every attempt fails; failures are not cached."""
    key = f"{spot['lng']:.6f},{spot['lat']:.6f}"
    if key not in cache:
        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(NLSC_URL.format(lng=spot["lng"], lat=spot["lat"]), timeout=30) as response:
                    root = ET.fromstring(response.read())
                break
            except (OSError, ET.ParseError):  # OSError covers timeouts, URLError and HTTPError
                if attempt == attempts - 1:
                    return None
                time.sleep(2 ** attempt)
        cache[key] = [root.findtext("ctyName") or "", root.findtext("townName") or ""]
        cache_file.write_text(json.dumps(cache, ensure_ascii=False, indent=0))
    return cache[key]


def full_address(city, district, address):
    # Drop a leading postal code and the city/county itself (台 or 臺); a 縣轄市 such as 竹北市 stays.
    address = re.sub(r"^\d{3,6}\s*", "", address.strip())
    address = re.sub("^" + city.replace("臺", "[臺台]"), "", address)
    # Add the district only when the address lacks it anywhere (新竹市's district is the city itself).
    named = district in address or district == city or re.match(r"\S{1,3}區", address)
    return city + ("" if named else district) + address


def apply_official(spot, lot, meters, score, source_name):
    """Official lot fields replace community guesses; returns the change log."""
    changes = []
    if spot["name"] != lot["name"]:
        changes.append(f"名稱：{spot['name']} → {lot['name']}")
        if spot["name"] not in lot["name"]:
            spot["note"] = "\n".join(filter(None, [f"來源原名稱：{spot['name']}", spot["note"]]))
        spot["name"] = lot["name"]
    if lot["address"]:
        spot["address"] = full_address(spot["city"], spot["district"], lot["address"])
        changes.append(f"地址：{spot['address']}")
    kind = facility_type(lot["name"] + lot["summary"])
    if kind:
        spot["facility_type"] = kind
    if lot["fee"]:
        fee = re.sub(r"\s+", " ", lot["fee"]).strip()
        spot["fee_note"] = fee if len(fee) <= 200 else fee[:190].rstrip("，、；;") + "…（詳見現場公告）"
        changes.append("費率：改用官方公告")
    if lot["motor"]:
        spot["scooter_total"] = lot["motor"]
        changes.append(f"機車格數：{lot['motor']}")
    if lot["heavy"]:
        zones = spot["parking_zones"]
        if not any(z.get("access") == "heavyOnly" for z in zones):
            zones.append({"name": "重機專用格", "access": "heavyOnly"})
        for zone in zones:
            if zone.get("access") == "heavyOnly":
                zone["guide"] = f"官方資料：大型重機格 {lot['heavy']} 格"
        if spot["heavy_allowed"] is False:
            changes.append(f"待人工確認：官方資料有大型重機格 {lot['heavy']} 格，但來源回報禁停")
        else:
            changes.append(f"重機格數：{lot['heavy']}")
    # Official points are often lot centroids while community pins mark the
    # motorcycle entrance, so only a clearly misplaced pin is moved.
    if meters is None:
        changes.append("座標：官方資料無座標，依同行政區名稱比對，保留來源座標")
    elif meters > 400:
        changes.append(f"座標：距官方位置 {meters:.0f} 公尺，改用官方座標")
        spot["lat"], spot["lng"] = round(lot["lat"], 7), round(lot["lng"], 7)
    elif meters > 150:
        changes.append(f"待人工確認：距官方位置 {meters:.0f} 公尺，保留來源座標")
    spot["note"] = "\n".join(filter(None, [spot["note"], f"已比對{source_name}（{lot['id']}）"]))
    return {"official_id": lot["id"], "official_name": lot["name"], "distance_m": None if meters is None else round(meters), "name_score": round(score, 2), "changes": changes}


def pilot_name(*names):
    """Pilot lists shorten some names (忠信 for 忠信廣場), so a contained core also counts."""
    for name in filter(None, names):
        for pilot in TAIPEI_PILOT:
            if similarity(name, pilot) >= 0.8 or (len(core(pilot)) >= 2 and core(pilot) in core(name)):
                return pilot
    return None


def apply_taipei_rules(spot, official_name=""):
    """Taipei policy documents correct fees and access the community map may predate."""
    changes = []
    if spot["space_type"] == "paidMotorcycle":
        spot["fee_note"] = TAIPEI_ROADSIDE[0]
        changes.append("費率：改用臺北市路邊收費機車格重機費率（115/10/6 起）")
        return None, changes
    pilot = pilot_name(spot["name"], official_name) if spot["space_type"] == "offStreet" else None
    if pilot:
        zones = [zone for zone in spot["parking_zones"] if zone["name"] != "機車區"]
        spot["parking_zones"] = zones + [{"name": "機車區", "access": "scooterHeavy", "fee_note": f"大型重機{TAIPEI_PILOT[pilot]}"}]
        spot["special_rules"] = PILOT_RULES
        if spot["heavy_allowed"] is False:
            changes.append("待人工確認：列於臺北市路外試辦場域，但來源回報禁停")
            spot.update(heavy_allowed=None, heavy_conflict=True)
        changes.append(f"官方試辦場域：{pilot}，機車區重機費率 {TAIPEI_PILOT[pilot]}")
    return pilot, changes


def facility_key(spot, seen):
    """An unmatched off-street placemark joins a nearby unmatched one with the same facility name,
    so a facility's car-area and motorcycle-area pins become one spot with both zones."""
    if spot["space_type"] != "offStreet":
        return None
    for key, (kept, entry) in seen.items():
        if (not entry.get("official_id") and not entry.get("pilot") and kept["space_type"] == "offStreet"
                and distance(spot["lat"], spot["lng"], kept["lat"], kept["lng"]) <= 200
                and similarity(spot["name"], kept["name"]) >= 0.9 and qualifiers(spot["name"]) == qualifiers(kept["name"])):
            return key
    return None


def qualifiers(name):
    """Words that tell sibling lots apart (東側／西側, 一館／二館, 一期…); the name core drops them."""
    return set(re.findall(r"[東西南北]側|[一二三四五六七八九十\d]+[館期區站號]|[東西南北]區", name))


def cell(value):
    """Markdown table cell: source names carry fee separators such as `|`."""
    return str(value).replace("|", "\\|").replace("\n", " ")


def merge(kept, spot):
    """Placemarks for one facility (car area, motorcycle area…) become zones of one spot."""
    names = {zone["name"] for zone in kept["parking_zones"]}
    kept["parking_zones"] += [zone for zone in spot["parking_zones"] if zone["name"] not in names]
    for key in ("entrance_note", "parking_guide", "note", "special_rules"):
        lines = kept[key].splitlines()
        kept[key] = "\n".join(lines + [line for line in spot[key].splitlines() if line not in lines])
    kept["unconfirmed"] = kept.get("unconfirmed") and spot.get("unconfirmed")
    if spot.get("heavy_conflict"):  # a conflict found earlier survives whichever record is kept
        kept.update(heavy_allowed=None, heavy_conflict=True)
        return ""
    if None not in (kept["heavy_allowed"], spot["heavy_allowed"]) and kept["heavy_allowed"] != spot["heavy_allowed"]:
        kept.update(heavy_allowed=None, heavy_conflict=True)
        return "待人工確認：來源對同一場站的重機可停回報不一致"
    # None from a conflict stays None for review; only an unknown value is filled in.
    if kept["heavy_allowed"] is None and not kept.get("heavy_conflict"):
        kept["heavy_allowed"] = spot["heavy_allowed"]
    return ""


def clip(spot):
    """Database limits: name 1–100, fee_note ≤200, note ≤500 characters."""
    spot["name"] = re.sub(r"〔.*?〕|\s+", " ", spot["name"]).strip()[:100] or "匯入停車點"
    for key, limit in (("fee_note", 200), ("note", 500), ("entrance_note", 500), ("parking_guide", 500), ("special_rules", 500)):
        if len(spot[key]) > limit:
            spot[key] = spot[key][:limit - 1] + "…"


def build(kml, mid, cache, imported_on, refresh=False, tdx_env=None):
    lots, failed = official_lots(cache, refresh, tdx_env)
    geo_file = cache / "nlsc.json"
    geo = json.loads(geo_file.read_text()) if geo_file.exists() else {}
    spots, report, skipped, seen = [], [], [], {}
    for mark in placemarks(kml):
        spot = normalize(mark)
        if spot is None:
            skipped.append(f"{mark['layer']}｜{mark['name']}")
            continue
        located = locate(spot, geo_file, geo)
        if located is None:
            skipped.append(f"{mark['layer']}｜{mark['name']}（行政區查詢失敗，未匯入；重跑會再查詢）")
            continue
        city, district = located
        if not city:
            skipped.append(f"{mark['layer']}｜{mark['name']}（座標不在臺灣行政區內）")
            continue
        spot.update(city=city, district=district)
        if re.fullmatch(r"[\d.,\s]+", spot["name"]):
            spot["name"] = f"{district}{'重機專用格' if spot['parking_zones'] else '停車點'}"
        entry = {"layer": mark["layer"], "source_name": mark["name"]}
        # The city's own dataset first: TDX repeats many of its lots under other ids,
        # and one id per facility is what merges a facility's placemarks.
        best = None
        if spot["space_type"] == "offStreet":
            city_lots = lots.get(city, [])
            best = (match_lot(spot, [lot for lot in city_lots if lot["source"] != TDX_SOURCE])
                    or match_lot(spot, [lot for lot in city_lots if lot["source"] == TDX_SOURCE]))
        if best:
            entry.update(apply_official(spot, best[1], best[2], best[3], best[1]["source"]))
            spot["lot"] = best[1]
        if city == "臺北市":
            pilot, changes = apply_taipei_rules(spot, entry.get("official_name", ""))
            entry.setdefault("changes", []).extend(changes)
            if pilot:
                entry["pilot"] = pilot
        # A pilot site is one facility however its placemarks were matched.
        key = (("pilot", entry["pilot"]) if entry.get("pilot") else entry.get("official_id")) \
            or facility_key(spot, seen) or (round(spot["lat"], 4), round(spot["lng"], 4), spot["name"])
        if key in seen:
            kept, kept_entry = seen[key]
            if entry.get("official_id") and not kept_entry.get("official_id"):
                # The officially matched placemark carries the facility's official facts, so it
                # becomes the kept record (in place, keeping the earlier id and list position).
                identity = {k: kept[k] for k in ("id", "source_name", "source_url", "license_note", "updated_at", "last_confirmed_at")}
                conflict = merge(spot, kept)
                kept.clear()
                kept.update(spot, **identity)
                kept_entry.update({k: v for k, v in entry.items() if k not in ("layer", "source_name")}, name=kept["name"])
            else:
                conflict = merge(kept, spot)
            kept_entry.setdefault("changes", []).extend(filter(None, [conflict]))
            kept_entry.setdefault("merged", []).append(mark["name"])
            clip(kept)
            skipped.append(f"{mark['layer']}｜{mark['name']}（與同一場站合併）")
            continue
        clip(spot)
        spot["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{VIEWER_URL.format(mid=mid)}|{mark['layer']}|{mark['name']}|{mark['points'][0]}"))
        spot.update(
            source_name="Alan大重停車記事（Google 我的地圖）", source_url=VIEWER_URL.format(mid=mid),
            license_note="社群地圖整理之事實資訊，經官方資料比對；請以現場公告為準",
            updated_at=f"{imported_on}T00:00:00Z", last_confirmed_at=None,
        )
        entry = {"id": spot["id"], "name": spot["name"], "city": city, "district": district, **entry}
        seen[key] = (spot, entry)
        spots.append(spot)
        report.append(entry)
    found = {entry.get("pilot") for _, entry in seen.values()}
    # Pilot sites come from 停管處 data; empty when it failed, and the report records why.
    taipei = [lot for lot in lots.get("臺北市", []) if lot["source"] == OFFICIAL["臺北市"][0]]
    for pilot in TAIPEI_PILOT if taipei else ():
        lot = max(taipei, key=lambda lot: similarity(pilot, lot["name"]))
        if pilot in found or similarity(pilot, lot["name"]) < 0.8:
            continue
        nearby = [s for s in spots if s["city"] == "臺北市" and s["space_type"] == "offStreet"
                  and distance(s["lat"], s["lng"], lot["lat"], lot["lng"]) <= 150 and similarity(s["name"], pilot) >= 0.4]
        if nearby:
            entry = next(e for kept, e in seen.values() if kept is nearby[0])
            entry.setdefault("changes", []).extend(apply_taipei_rules(nearby[0], pilot)[1])
            entry["pilot"] = pilot
            nearby[0].setdefault("lot", lot)
    official, community = [], []
    entries = {entry["id"]: entry for entry in report}
    for spot in spots:
        entry = entries[spot["id"]]
        if spot.get("lot"):
            official.append(official_spot(spot["lot"], spot, entry.get("pilot"), lots, imported_on))
            entry["result"] = "官方點"
        elif spot["unconfirmed"]:
            entry["result"] = "不錄入：來源標示未確認且未通過官方核驗"
        else:
            community.append(spot | {"source_name": COMMUNITY_SOURCE,
                                     "license_note": "整理自 Alan大重停車記事（Google 我的地圖）；未通過官方核驗，請以現場公告為準"})
            entry["result"] = "社群點（待確認）"
    used = {spot["lot"]["id"] for spot in spots if spot.get("lot")}
    for lot, pilot in official_additions(lots, used, official):
        located = locate(lot, geo_file, geo)
        if located is None:
            skipped.append(f"官方補入｜{lot['name']}（行政區查詢失敗，未匯入；重跑會再查詢）")
            continue
        city, district = located
        if not city:
            continue
        addition = official_spot(lot | {"city": city, "district": district}, None, pilot, lots, imported_on)
        official.append(addition)
        report.append({"id": addition["id"], "name": lot["name"], "city": city, "district": district, "layer": "官方補入",
                       "source_name": lot["name"], "official_id": lot["id"], "official_name": lot["name"], "distance_m": 0,
                       "name_score": 1.0, "result": "官方點（官方補入）", "changes": []})
    sources = {city: sorted({lot["source"] for lot in rows}) for city, rows in lots.items() if rows}
    return [output(s) for s in official], [output(s) for s in community], report, skipped, failed, sources


OUTPUT_ORDER = ["id", "name", "lat", "lng", "city", "district", "source", "space_type", "facility_type", "parking_access",
                "fee_note", "heavy_allowed", "scooter_allowed", "status", "scooter_total", "available", "updated_at",
                "last_confirmed_at", "note", "address", "road_segment", "entrance_note", "parking_guide", "special_rules",
                "parking_zones", "source_name", "source_url", "license_note", "source_id"]
NULLABLE = {"heavy_allowed", "scooter_allowed", "scooter_total", "available", "last_confirmed_at", "note"}


def output(spot):
    return {k: spot[k] for k in OUTPUT_ORDER if k in spot and (spot[k] not in ("", [], None) or k in NULLABLE)}


def government(city):
    return f"{city}政府"


def official_spot(lot, spot, pilot, lots, imported_on):
    """An official spot states only what official sources state; community facts become labelled notes."""
    city = spot["city"] if spot else lot["city"]
    heavy = bool(lot["heavy"]) or bool(pilot)
    zones = []
    if lot["heavy"]:
        zones.append({"name": "重機專用格", "access": "heavyOnly", "guide": f"官方資料：大型重機格 {lot['heavy']} 格"})
    if pilot:
        zones.append({"name": "機車區", "access": "scooterHeavy", "fee_note": f"大型重機{TAIPEI_PILOT[pilot]}"})
    notes = []
    if spot:
        claim = {True: "大型重機可停", False: "大型重機禁停", None: ""}[spot["heavy_allowed"]]
        areas = "、".join(f"{z['name']}（{z['fee_note']}）" if z.get("fee_note") else z["name"] for z in spot["parking_zones"]
                         if z["name"] != "機車區" or not pilot)
        community = "；".join(filter(None, [claim, areas and f"停放區域：{areas}"]))
        notes += [f"社群補充（未經官方查核）：{community}" if community else "", spot["note"]]
    fee = re.sub(r"\s+", " ", lot["fee"]).strip()
    official = {
        "id": "official:" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{lot['url']}|{lot['id']}")),
        "name": display_name(lot, city)[:100], "lat": spot["lat"] if spot else round(lot["lat"], 7), "lng": spot["lng"] if spot else round(lot["lng"], 7),
        "city": city, "district": spot["district"] if spot else lot["district"], "source": "official", "space_type": "offStreet",
        "facility_type": facility_type(lot["name"] + lot.get("summary", "")) or (spot or {}).get("facility_type"),
        "fee_note": (fee if len(fee) <= 200 else fee[:190].rstrip("，、；;") + "…（詳見現場公告）") or "請依現場公告",
        "heavy_allowed": True if heavy else None, "scooter_allowed": True if lot["motor"] else None,
        "status": "confirmed", "scooter_total": lot["motor"] or None, "available": None,
        "updated_at": f"{imported_on}T00:00:00Z", "last_confirmed_at": f"{imported_on}T00:00:00Z",
        "note": "\n".join(filter(None, notes)),
        "address": (spot or {}).get("address") or (full_address(city, lot["district"], lot["address"]) if lot["address"] else ""),
        "entrance_note": (spot or {}).get("entrance_note", ""), "parking_guide": (spot or {}).get("parking_guide", ""),
        "special_rules": PILOT_RULES if pilot else "", "parking_zones": zones,
        "source_name": government(city), "source_url": lot["url"],
        "license_note": "政府資料開放授權條款第 1 版" + ("；社群補充整理自 Alan大重停車記事（Google 我的地圖）" if spot else ""),
        "source_id": lot["id"],
    }
    for key in ("entrance_note", "parking_guide"):
        if official[key]:
            official[key] = "社群補充（未經官方查核）：\n" + official[key]
    clip(official)
    official["address"] = official["address"][:200]
    return official


def display_name(lot, city):
    """Taichung's TDX names keep the city dataset's `district-agency-nameP` form, which matching uses but riders need not read."""
    return taichung_name(lot["name"]) if lot["source"] == TDX_SOURCE and city == "臺中市" else lot["name"]


def same_bays(a, b):
    """One lot, even when TDX names it differently: within 30 m with nearly the same motorcycle bay count, or within
    150 m with exactly the same sizeable count (sources place 南科車站東側 47 m apart, both with 236 bays)."""
    if not (a["motor"] and b["motor"]):
        return False
    meters = distance(a["lat"], a["lng"], b["lat"], b["lng"])
    if meters <= 30:
        return abs(a["motor"] - b["motor"]) <= max(3, 0.03 * max(a["motor"], b["motor"]))
    return meters <= 150 and a["motor"] == b["motor"] >= 20


def official_additions(lots, used, placed=()):
    """Government lots missing from the map that matter to a mode: motorcycle bays (一般機車) or heavy evidence (重機).
    TDX lots are static data here; one that repeats a city dataset lot or an already placed official spot is skipped,
    and so is a city dataset lot repeating a spot placed from TDX (a map spot that matched TDX rather than the city lot)."""
    def repeats(lot, others):
        probe = {"name": display_name(lot, city), "lat": lot["lat"], "lng": lot["lng"]}
        return match_lot(probe, others) or any(same_bays(lot, other) for other in others)

    for city, rows in lots.items():
        placed_here = [{"name": spot["name"], "lat": spot["lat"], "lng": spot["lng"], "motor": spot.get("scooter_total") or 0,
                        "tdx": spot["source_id"].startswith("TDX-")} for spot in placed if spot["city"] == city]
        own = [lot for lot in rows if lot["source"] != TDX_SOURCE and lot["lat"] is not None] + placed_here
        from_tdx = [spot for spot in placed_here if spot["tdx"]]
        for lot in rows:
            if lot["id"] in used or lot["lat"] is None:
                continue
            pilot = pilot_name(lot["name"]) if lot["source"] == OFFICIAL.get("臺北市", ("",))[0] else None
            if not (lot["motor"] or lot["heavy"] or pilot):
                continue
            if repeats(lot, own if lot["source"] == TDX_SOURCE else from_tdx):
                continue
            used.add(lot["id"])
            yield lot | {"city": city}, pilot





def summary_markdown(official, community, report, skipped, imported_on, failed=(), sources=None):
    from collections import Counter
    verified = [r for r in report if r.get("result") == "官方點"]
    added = [r for r in report if r.get("result") == "官方點（官方補入）"]
    dropped = [r for r in report if r.get("result", "").startswith("不錄入")]
    lines = [f"# Google 我的地圖匯入與官方核驗報告（{imported_on}）", "",
             f"- 官方點：{len(official)}（我的地圖核驗通過 {len(verified)}、官方資料補入 {len(added)}）；資料來源為各縣市政府，`status=confirmed`",
             f"- 社群點：{len(community)}（未通過官方核驗，`status=pending`，資料來源「{COMMUNITY_SOURCE}」）",
             f"- 不錄入：{len(dropped)}（來源地圖自己標示未確認，且未通過官方核驗）",
             f"- 略過或合併：{len(skipped)}"]
    lines += [f"- 官方資料取得失敗：{reason}" for reason in failed]
    lines += ["", "## 縣市分布", "", "| 縣市 | 官方點（核驗） | 官方點（補入） | 社群點 | 官方資料 |", "| --- | --- | --- | --- | --- |"]
    cities = Counter(s["city"] for s in official + community)
    for city, _ in cities.most_common():
        source = "、".join((sources or {}).get(city, [])) or "無可用路外停車場資料，僅驗證行政區"
        lines.append(f"| {city} | {sum(r['city'] == city for r in verified)} | {sum(r['city'] == city for r in added)} | "
                     f"{sum(s['city'] == city for s in community)} | {cell(source)} |")
    lines += ["", "## 官方點重機資格", "",
              f"- 官方明載可停：{sum(s['heavy_allowed'] is True for s in official)}（臺北市大型重機格與 36 處路外試辦場域）",
              f"- 未記載（App 顯示有條件）：{sum(s['heavy_allowed'] is None for s in official)}；我的地圖的重機回報列於備註「社群補充」",
              "", "## 需人工確認", ""]
    lines += [f"- {r['name']}（{r['city']}{r['district']}）：{c}" for r in report for c in r.get("changes", []) if c.startswith(("待人工確認", "座標"))] or ["- 無"]
    lines += ["", "## 核驗修正", "", "| 點位 | 官方編號 | 距離 | 修正 |", "| --- | --- | --- | --- |"]
    distance_text = lambda r: "—" if r.get("distance_m") is None else f"{r['distance_m']} m"
    lines += [f"| {cell(r['source_name'])} | {cell(r.get('official_id') or r.get('pilot', ''))} | {distance_text(r)} | "
              f"{cell('；'.join(c for c in r.get('changes', []) if not c.startswith('地址')))} |" for r in verified]
    lines += ["", "## 不錄入", ""] + [f"- {r['layer']}｜{r['source_name']}" for r in dropped] or ["- 無"]
    lines += ["", "## 略過或合併", ""] + [f"- {s}" for s in skipped]
    return "\n".join(lines) + "\n"


# What the Admin Web import page accepts, as admin_import_plan() in
# supabase/migrations/202610260250_admin_import.sql checks it: the columns it
# writes, their types, and the entry-level rules that mark a spot invalid.
IMPORT_TEXT = ["name", "city", "district", "space_type", "fee_note", "note", "source_url", "source_name", "license_note",
               "address", "road_segment", "entrance_note", "parking_guide", "special_rules", "facility_type", "parking_access"]
IMPORT_TYPES = {**{k: str for k in IMPORT_TEXT}, "lat": (int, float), "lng": (int, float), "heavy_allowed": bool,
                "scooter_allowed": bool, "scooter_total": int, "parking_zones": list, "fee": dict}
UUID_RE = re.compile(r"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def importable(spot, seen=None):
    """Why the Admin Web import page would refuse this spot, or "" when it would take it.

    `seen` holds the ids already checked in the same file; a repeated id is refused."""
    spot_id = spot.get("id")
    official = isinstance(spot_id, str) and spot_id.startswith("official:")
    if not isinstance(spot_id, str) or not UUID_RE.match(spot_id.removeprefix("official:")):
        return "沒有可辨識的 id"
    if seen is not None:
        if spot_id in seen:
            return "檔案中重複的 id"
        seen.add(spot_id)
    if spot.get("source") != ("official" if official else "import"):
        return "來源與 id 不符（官方點 id 以 official: 開頭，社群點 source 為 import）"
    for key, kind in IMPORT_TYPES.items():
        value = spot.get(key)
        # Stricter than the page, which lets Postgres read "25.0" into a number: the tool
        # writes the tables' own types. bool is an int in Python, but not a count.
        if value is not None and (not isinstance(value, kind) or (kind is int and isinstance(value, bool))):
            return f"欄位型別錯誤：{key}"
    name = spot.get("name") or ""
    if not name.strip() or len(name) > 100:
        return "名稱需為 1–100 字"
    lat, lng = spot.get("lat"), spot.get("lng")
    if lat is None or lng is None or not (20 <= lat <= 27 and 118 <= lng <= 123):
        return "座標不在台灣範圍內"
    if not (spot.get("city") or "").strip():
        return "缺少縣市"
    if official and (not (spot.get("source_url") or "").startswith("https://") or not (spot.get("source_name") or "").strip()):
        return "官方點需要資料來源與 https 官方資料網址"
    return ""


def unimportable(spots):
    """`(index, name, reason)` for every spot the Admin Web import page would refuse."""
    seen = set()
    problems = []
    for n, spot in enumerate(spots):
        reason = importable(spot, seen)
        if reason:
            problems.append((n, spot.get("name") or "", reason))
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mid", required=True, help="My Maps id (the `mid` query parameter)")
    parser.add_argument("--kml", type=Path, help="local KML export; downloaded from My Maps when omitted")
    parser.add_argument("--cache", type=Path, default=Path("artifacts/mymaps-cache"))
    parser.add_argument("--output", type=Path, required=True,
                        help="directory for community spots.json (for the Admin Web import page), verification.json and REPORT.md")
    parser.add_argument("--official-output", type=Path, default=Path("data/imports/official"),
                        help="directory for official spots.json (for the Admin Web import page)")
    parser.add_argument("--date", default=date.today().isoformat(), help="import date written to updated_at")
    parser.add_argument("--refresh", action="store_true", help="re-download KML and official datasets")
    parser.add_argument("--tdx-env", type=Path, default=Path("supabase/functions/.env"),
                        help="env file with TDX_CLIENT_ID/TDX_CLIENT_SECRET (environment variables take precedence)")
    args = parser.parse_args()
    kml = args.kml or fetch(KML_URL.format(mid=args.mid), args.cache / f"{args.mid}.kml", args.refresh)
    official, community, report, skipped, failed, sources = build(kml, args.mid, args.cache, args.date, args.refresh, args.tdx_env)
    for directory in (args.output, args.official_output):
        directory.mkdir(parents=True, exist_ok=True)
    (args.official_output / "spots.json").write_text(json.dumps(official, ensure_ascii=False, indent=2) + "\n")
    (args.output / "spots.json").write_text(json.dumps(community, ensure_ascii=False, indent=2) + "\n")
    (args.output / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (args.output / "REPORT.md").write_text(summary_markdown(official, community, report, skipped, args.date, failed, sources))
    # The files are written first so a refused spot can be looked at; the Admin Web
    # import page is the only way into the database, so a file it would refuse fails here.
    problems = [(args.official_output / "spots.json", *p) for p in unimportable(official)] \
        + [(args.output / "spots.json", *p) for p in unimportable(community)]
    for path, n, name, reason in problems:
        print(f"{path}: 第 {n + 1} 筆「{name}」管理站無法匯入：{reason}")
    if problems:
        raise SystemExit(1)
    print(f"Prepared {len(official)} official and {len(community)} community spots for the Admin Web import page; "
          "no database writes performed")


if __name__ == "__main__":
    main()
