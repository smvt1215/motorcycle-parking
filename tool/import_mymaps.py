"""Normalize a Google My Maps KML export into project spots, checked against official open data.

Pipeline: KML placemarks → layer/icon mapping → NLSC city/district lookup →
Taipei/New Taipei off-street lot matching → `ParkingSpot` JSON + review report.
Every imported spot stays `pending`; the report lists each official correction.
"""
import argparse
from datetime import date
import html
import json
import math
from pathlib import Path
import re
import urllib.request
import uuid
import xml.etree.ElementTree as ET

KML_URL = "https://www.google.com/maps/d/kml?mid={mid}&forcekml=1"
VIEWER_URL = "https://www.google.com/maps/d/viewer?mid={mid}"
NLSC_URL = "https://api.nlsc.gov.tw/other/TownVillagePointQuery/{lng}/{lat}/4326"
OFFICIAL = {
    "臺北市": ("臺北市停車場資訊（臺北市停車管理工程處）", "https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_alldesc.json"),
    "新北市": ("新北市路外公共停車場資訊（新北市政府交通局）", "https://data.ntpc.gov.tw/api/datasets/B1464EF0-9C7C-4A6F-ABF7-6BDF32847E68/json?page={page}&size=1000"),
}
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
# 115/10/6 起臺北市公有路邊收費機車格全面開放大型重機停放。
TAIPEI_ROADSIDE = ("大型重機每次 40 元，可斜停 2 格（臺北市 115/10/6 起）",
                   "https://www.gov.taipei/News_Content.aspx?n=F0DDAF49B89E9413&sms=72544237BBE4C5F6&s=8BC5F23730A95E42")
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
# Operator brands and parking words say nothing about which lot a name means.
GENERIC = re.compile(
    r"(?i)嘟嘟房|city ?parking|城市車旅|times|168 ?parking|168停車聯盟|正好停|俥亭|uspace|台灣聯通|富山停車|歐特儀|康達盛通|吉拾|"
    r"[臺新][北中南東]市|桃園市|高雄市|基隆市|新竹[市縣]|嘉義[市縣]|苗栗縣|彰化縣|南投縣|雲林縣|屏東縣|宜蘭縣|花蓮縣|臺東縣|澎湖縣|金門縣|連江縣|"
    r"停車場|停車|地下|立體|平面|公有|附設|機車|汽車|重機|專用|大樓|股份有限公司|市立|[東西南北]側|[區店站格]|"
    r"[()（）\s\-‧・·|｜/、,，.。:&⇦\[\]]"
)


def fetch(url, path, refresh=False):
    if refresh or not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url, timeout=60) as response:
            path.write_bytes(response.read())
    return path


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
    for raw in re.split(r"\s*[|｜]\s*|\s+-\s+|(?<=\d):(?=\D)", text):
        match = re.fullmatch(r"(假日限定|展期|無展|[平假黃紅日夜機汽])?\s*:?\s*(\d+)\s*/?\s*(\d*)\s*(h|d|次|隔夜)?(.*)", raw)
        if match:
            hours = f"每 {match[3]} 小時" if match[3] else "每小時"
            unit = {"h": hours, "d": "每日", "隔夜": "隔夜"}.get(match[4] or "", "每次")
            parts.append(f"{prefixes.get(match[1] or '', '')}{unit} {match[2]} 元{match[5].strip(' :')}")
        elif raw:
            parts.append(re.sub(r"(?i)free\s*/\s*(\d+)h", r"免費 \1 小時", raw).replace("Free", "免費"))
    return "；".join(parts) or "請依現場公告"


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


def normalize(mark):
    """One placemark → project spot fields (city/district filled later), or None when not a parking point."""
    layer, icon, color = mark["layer"], mark["icon"], mark["color"]
    if layer not in FEE_BASIS or icon == "1502":
        return None  # shops, and district-level policy notes that belong to city rules
    name, fee_text = split_name(mark["name"])
    lines = clean_text(mark["description"])
    lng, lat = mark["points"][len(mark["points"]) // 2]
    spot = {
        "name": name, "lat": round(lat, 7), "lng": round(lng, 7), "source": "import", "status": "pending",
        "fee_note": parse_fee(fee_text), "heavy_allowed": True, "scooter_allowed": None,
        "scooter_total": None, "available": None, "note": "", "address": "", "road_segment": "",
        "entrance_note": "", "parking_guide": "", "special_rules": "", "parking_zones": [],
    }
    entries = [line for line in lines if ENTRY.search(line)]
    others = [line for line in lines if line not in entries]
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
        spot["note"] = "\n".join(lines)
    else:
        spot.update(space_type="offStreet")
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
        spot["entrance_note"] = "\n".join(entries)
        spot["note"] = "\n".join(others)
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
    for pattern, kind in (("地下", "underground"), ("立體|塔|大樓|機械|建築", "multiStorey"), ("平面|橋下|露天|廣場", "surface")):
        if re.search(pattern, text):
            return kind
    return None


def official_lots(cache, refresh=False):
    """City → list of normalized official lots with WGS84 coordinates."""
    lots = {"臺北市": [], "新北市": []}
    tpe = json.loads(fetch(OFFICIAL["臺北市"][1], cache / "tpe_alldesc.json", refresh).read_text(encoding="utf-8-sig"))
    for row in tpe["data"]["park"]:
        lat, lng = tm2_to_wgs84(float(row["tw97x"]), float(row["tw97y"]))
        lots["臺北市"].append({
            "id": row["id"], "name": row["name"], "address": row["address"], "fee": row["payex"], "summary": row["summary"],
            "motor": int(row["totalmotor"] or 0), "heavy": int(row.get("totallargemotor") or 0), "lat": lat, "lng": lng,
        })
    page = 0
    while True:
        rows = json.loads(fetch(OFFICIAL["新北市"][1].format(page=page), cache / f"ntpc_{page}.json", refresh).read_text())
        for row in rows:
            if not row["TW97X"] or not row["TW97Y"]:
                continue
            lat, lng = tm2_to_wgs84(float(row["TW97X"]), float(row["TW97Y"]))
            lots["新北市"].append({
                "id": row["ID"], "name": row["NAME"], "address": row["ADDRESS"], "fee": row["PAYEX"], "summary": row["SUMMARY"],
                "motor": int(row["TOTALMOTOR"] or 0), "heavy": 0, "lat": lat, "lng": lng,
            })
        if len(rows) < 1000:
            return lots
        page += 1


def match_lot(spot, lots):
    """Best official lot: distance alone is not evidence, so closer lots need less name similarity."""
    best = None
    for lot in lots:
        meters = distance(spot["lat"], spot["lng"], lot["lat"], lot["lng"])
        if meters > 600:
            continue
        score = similarity(spot["name"], lot["name"])
        if (meters <= 80 and score >= 0.45) or (meters <= 200 and score >= 0.6) or score >= 0.8:
            # Equal cores (洲子站, 洲子立體停車場) are told apart by the full names before distance.
            rank = (round(score - meters / 1000, 1), dice(spot["name"], lot["name"]), -meters)
            if best is None or rank > best[0]:
                best = (rank, lot, meters, score)
    return best


def locate(spot, cache_file, cache):
    key = f"{spot['lng']:.6f},{spot['lat']:.6f}"
    if key not in cache:
        with urllib.request.urlopen(NLSC_URL.format(lng=spot["lng"], lat=spot["lat"]), timeout=30) as response:
            root = ET.fromstring(response.read())
        cache[key] = [root.findtext("ctyName") or "", root.findtext("townName") or ""]
        cache_file.write_text(json.dumps(cache, ensure_ascii=False, indent=0))
    return cache[key]


def apply_official(spot, lot, meters, score, source_name):
    """Official lot fields replace community guesses; returns the change log."""
    changes = []
    if spot["name"] != lot["name"]:
        changes.append(f"名稱：{spot['name']} → {lot['name']}")
        if spot["name"] not in lot["name"]:
            spot["note"] = "\n".join(filter(None, [f"來源原名稱：{spot['name']}", spot["note"]]))
        spot["name"] = lot["name"]
    if lot["address"]:
        address = re.sub(r"^(新北市|臺北市|台北市)", "", lot["address"])
        spot["address"] = spot["city"] + ("" if re.match(r"\S{1,3}區", address) else spot["district"]) + address
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
    if meters > 400 and score >= 0.8:
        changes.append(f"座標：距官方位置 {meters:.0f} 公尺，改用官方座標")
        spot["lat"], spot["lng"] = round(lot["lat"], 7), round(lot["lng"], 7)
    elif meters > 150:
        changes.append(f"待人工確認：距官方位置 {meters:.0f} 公尺，保留來源座標")
    spot["note"] = "\n".join(filter(None, [spot["note"], f"已比對{source_name}（{lot['id']}）"]))
    return {"official_id": lot["id"], "official_name": lot["name"], "distance_m": round(meters), "name_score": round(score, 2), "changes": changes}


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
            spot["heavy_allowed"] = None
        changes.append(f"官方試辦場域：{pilot}，機車區重機費率 {TAIPEI_PILOT[pilot]}")
    return pilot, changes


def merge(kept, spot):
    """Placemarks for one facility (car area, motorcycle area…) become zones of one spot."""
    names = {zone["name"] for zone in kept["parking_zones"]}
    kept["parking_zones"] += [zone for zone in spot["parking_zones"] if zone["name"] not in names]
    for key in ("entrance_note", "note", "special_rules"):
        lines = kept[key].splitlines()
        kept[key] = "\n".join(lines + [line for line in spot[key].splitlines() if line not in lines])
    if None not in (kept["heavy_allowed"], spot["heavy_allowed"]) and kept["heavy_allowed"] != spot["heavy_allowed"]:
        kept["heavy_allowed"] = None
        return "待人工確認：來源對同一場站的重機可停回報不一致"
    # A pilot lot reset to None by a conflicting ban stays None for review.
    if kept["heavy_allowed"] is None and kept.get("special_rules") != PILOT_RULES:
        kept["heavy_allowed"] = spot["heavy_allowed"]
    return ""


def clip(spot):
    """Database limits: name 1–100, fee_note ≤200, note ≤500 characters."""
    spot["name"] = re.sub(r"〔.*?〕|\s+", " ", spot["name"]).strip()[:100] or "匯入停車點"
    for key, limit in (("fee_note", 200), ("note", 500), ("entrance_note", 500), ("special_rules", 500)):
        if len(spot[key]) > limit:
            spot[key] = spot[key][:limit - 1] + "…"


def build(kml, mid, cache, imported_on, refresh=False):
    lots = official_lots(cache, refresh)
    geo_file = cache / "nlsc.json"
    geo = json.loads(geo_file.read_text()) if geo_file.exists() else {}
    spots, report, skipped, seen = [], [], [], {}
    for mark in placemarks(kml):
        spot = normalize(mark)
        if spot is None:
            skipped.append(f"{mark['layer']}｜{mark['name']}")
            continue
        city, district = locate(spot, geo_file, geo)
        if not city:
            skipped.append(f"{mark['layer']}｜{mark['name']}（座標不在臺灣行政區內）")
            continue
        spot.update(city=city, district=district)
        if re.fullmatch(r"[\d.,\s]+", spot["name"]):
            spot["name"] = f"{district}{'重機專用格' if spot['parking_zones'] else '停車點'}"
        entry = {"layer": mark["layer"], "source_name": mark["name"]}
        best = match_lot(spot, lots.get(city, [])) if spot["space_type"] == "offStreet" else None
        if best:
            entry.update(apply_official(spot, best[1], best[2], best[3], OFFICIAL[city][0]))
        if city == "臺北市":
            pilot, changes = apply_taipei_rules(spot, entry.get("official_name", ""))
            entry.setdefault("changes", []).extend(changes)
            if pilot:
                entry["pilot"] = pilot
        key = entry.get("official_id") or (round(spot["lat"], 4), round(spot["lng"], 4), spot["name"])
        if key in seen:
            conflict = merge(seen[key][0], spot)
            seen[key][1].setdefault("changes", []).extend(filter(None, [conflict]))
            seen[key][1].setdefault("merged", []).append(mark["name"])
            clip(seen[key][0])
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
    for pilot, fee in TAIPEI_PILOT.items():
        lot = max(lots["臺北市"], key=lambda lot: similarity(pilot, lot["name"]))
        if pilot in found or similarity(pilot, lot["name"]) < 0.8:
            continue
        nearby = [s for s in spots if s["city"] == "臺北市" and s["space_type"] == "offStreet"
                  and distance(s["lat"], s["lng"], lot["lat"], lot["lng"]) <= 150 and similarity(s["name"], pilot) >= 0.4]
        if nearby:
            entry = next(e for kept, e in seen.values() if kept is nearby[0])
            entry.setdefault("changes", []).extend(apply_taipei_rules(nearby[0], pilot)[1])
            entry["pilot"] = pilot
            continue
        city, district = locate({"lat": lot["lat"], "lng": lot["lng"]}, geo_file, geo)
        spot = {
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{TAIPEI_PILOT_URLS[0]}|{lot['id']}")), "name": lot["name"],
            "lat": round(lot["lat"], 7), "lng": round(lot["lng"], 7), "city": city, "district": district, "source": "import",
            "space_type": "offStreet", "facility_type": facility_type(lot["name"] + lot["summary"]), "fee_note": lot["fee"][:200],
            "heavy_allowed": True, "scooter_allowed": True, "status": "pending", "scooter_total": lot["motor"] or None,
            "available": None, "updated_at": f"{imported_on}T00:00:00Z", "last_confirmed_at": None,
            "note": f"官方試辦清單補入，來源地圖未收錄；已比對{OFFICIAL['臺北市'][0]}（{lot['id']}）",
            "address": lot["address"], "special_rules": PILOT_RULES,
            "parking_zones": [{"name": "機車區", "access": "scooterHeavy", "fee_note": f"大型重機{fee}"}],
            "source_name": "臺北市停車管理工程處新聞稿", "source_url": TAIPEI_PILOT_URLS[1], "license_note": "政府資料開放授權條款第 1 版",
        }
        spots.append(spot)
        report.append({"id": spot["id"], "name": lot["name"], "city": city, "district": district, "layer": "官方補入",
                       "source_name": pilot, "official_id": lot["id"], "official_name": lot["name"], "distance_m": 0,
                       "name_score": round(similarity(pilot, lot["name"]), 2), "changes": ["官方試辦場域：來源地圖未收錄，依官方資料補入"]})
    order = ["id", "name", "lat", "lng", "city", "district", "source", "space_type", "facility_type", "parking_access",
             "fee_note", "heavy_allowed", "scooter_allowed", "status", "scooter_total", "available", "updated_at",
             "last_confirmed_at", "note", "address", "road_segment", "entrance_note", "parking_guide", "special_rules",
             "parking_zones", "source_name", "source_url", "license_note"]
    spots = [{k: s[k] for k in order if k in s and (s[k] not in ("", []) or k == "note")} for s in spots]
    return spots, report, skipped


def summary_markdown(spots, report, skipped, imported_on):
    from collections import Counter
    matched = [r for r in report if "official_id" in r]
    lines = [f"# Google 我的地圖匯入查核報告（{imported_on}）", "",
             f"- 匯入點位：{len(spots)}（全部 `status=pending`，待社群或管理者確認）",
             f"- 官方路外停車場比對成功：{len(matched)}（臺北市 {sum(r['city'] == '臺北市' for r in matched)}、新北市 {sum(r['city'] == '新北市' for r in matched)}）",
             f"- 略過或合併：{len(skipped)}", "", "## 縣市分布", ""]
    lines += [f"- {city}：{count}" for city, count in Counter(s["city"] for s in spots).most_common()]
    lines += ["", "## 類型分布", ""]
    lines += [f"- {kind}：{count}" for kind, count in Counter(s["space_type"] for s in spots).most_common()]
    lines += ["", "## 需人工確認", ""]
    lines += [f"- {r['name']}（{r['city']}{r['district']}）：{c}" for r in report for c in r.get("changes", []) if c.startswith(("待人工確認", "座標"))] or ["- 無"]
    lines += ["", "## 官方比對修正", "", "| 點位 | 官方編號 | 距離 | 修正 |", "| --- | --- | --- | --- |"]
    lines += [f"| {r['source_name']} | {r['official_id']} | {r['distance_m']} m | {'；'.join(c for c in r['changes'] if not c.startswith('地址'))} |" for r in matched]
    lines += ["", "## 略過或合併", ""] + [f"- {s}" for s in skipped]
    return "\n".join(lines) + "\n"


def literal(value):
    return "null" if value is None else "'" + str(value).replace("'", "''") + "'"


def sql(spots, owner):
    """Pending community_spots rows; extended detail fields stay in the JSON until the schema has columns."""
    owner = str(uuid.UUID(owner))
    keys = ["id", "name", "city", "district", "space_type", "fee_note", "note", "source_name", "source_url", "license_note"]
    rows = ["-- Generated by tool/import_mymaps.py. Review before execution; all points remain pending.", "begin;"]
    for s in spots:
        values = ",".join(literal(s.get(k, "")) for k in keys)
        flags = ",".join("null" if s[k] is None else str(s[k]).lower() for k in ("heavy_allowed", "scooter_allowed"))
        rows.append(f"insert into public.community_spots(user_id,{','.join(keys)},heavy_allowed,scooter_allowed,scooter_total,lat,lng,source,status) "
                    f"values({literal(owner)},{values},{flags},{literal(s.get('scooter_total'))},{s['lat']},{s['lng']},'import','pending') on conflict(id) do nothing;")
    rows.append("commit;")
    return "\n".join(rows) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mid", required=True, help="My Maps id (the `mid` query parameter)")
    parser.add_argument("--kml", type=Path, help="local KML export; downloaded from My Maps when omitted")
    parser.add_argument("--cache", type=Path, default=Path("artifacts/mymaps-cache"))
    parser.add_argument("--output", type=Path, required=True, help="directory for spots.json and REPORT.md")
    parser.add_argument("--date", default=date.today().isoformat(), help="import date written to updated_at")
    parser.add_argument("--sql-owner", help="also write import.sql owned by this auth user id")
    parser.add_argument("--refresh", action="store_true", help="re-download KML and official datasets")
    args = parser.parse_args()
    kml = args.kml or fetch(KML_URL.format(mid=args.mid), args.cache / f"{args.mid}.kml", args.refresh)
    spots, report, skipped = build(kml, args.mid, args.cache, args.date, args.refresh)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "spots.json").write_text(json.dumps(spots, ensure_ascii=False, indent=2) + "\n")
    (args.output / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (args.output / "REPORT.md").write_text(summary_markdown(spots, report, skipped, args.date))
    if args.sql_owner:
        (args.cache / "import.sql").write_text(sql(spots, args.sql_owner))
    print(f"Prepared {len(spots)} spots in {args.output}; no database writes performed")


if __name__ == "__main__":
    main()
