"""Check My Maps normalization rules and the committed import against database limits."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import unittest.mock

import import_mymaps
from unittest.mock import patch

from import_mymaps import (
    PILOT_RULES, TAIPEI_PILOT, TDX_SOURCE, TAIPEI_ROADSIDE, apply_official, apply_taipei_rules, cell, clean_text, display_name,
    entry_direction, facility_key, importable, lot, locate, match_lot, merge, hccg_context, kaohsiung, midpoint, normalize,
    official_additions, official_lots, official_spot, parse_fee, split_name, taichung_name, tdx_credentials, tdx_lots, tm2_to_wgs84,
    unimportable,
)

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data/imports/google-mymaps/spots.json"
OFFICIAL_DATA = ROOT / "data/imports/official/spots.json"


def mark(layer, name, icon="1538", color="7CB342", description="", line=False):
    points = [(121.5, 25.0), (121.501, 25.001), (121.502, 25.002)] if line else [(121.5, 25.0)]
    return {"layer": layer, "name": name, "description": description, "icon": icon, "color": color, "line": line, "points": points}


class FeeTest(unittest.TestCase):
    def test_source_fee_shorthand_becomes_readable_text(self):
        cases = {
            "30/h": "每小時 30 元", "Free": "免費", "30/4h": "每 4 小時 30 元", "?": "請依現場公告", "--": "請依現場公告",
            "平50/h|假60/h": "平日每小時 50 元；假日每小時 60 元",
            "平:15/d|假:20/d": "平日每日 15 元；假日每日 20 元",
            "黃60/d | 紅100/d": "黃牌每日 60 元；紅牌每日 100 元",
            "30/d | 1200/隔夜": "每日 30 元；隔夜 1200 元",
            "20/h|60|d": "每小時 20 元；每日 60 元",
            "40/h - 管理員": "每小時 40 元；需按鈴或請管理員協助",
            "平30/h;200/d | 假40/h": "平日每小時 30 元；每日 200 元；假日每小時 40 元",
            "20/h - B2限悠遊卡": "每小時 20 元；悠遊卡進出",
            "50/半天": "每半天 50 元", "30/d | 600/月": "每日 30 元；每月 600 元",
            "40/d - 後牌停5/F": "每日 40 元；後車牌辨識",
            "free": "免費", "30/H": "每小時 30 元", "機車30/d": "機車每日 30 元",
            "室內30/h | 室外20/h": "室內每小時 30 元；室外每小時 20 元",
            # Notes riding on the fee keep only vocabulary facts (#275).
            "60/h左車道進": "每小時 60 元", "Free-機車": "免費", "30/d | 營業時間": "每日 30 元",
            "40/h - 倒退掃牌": "每小時 40 元；可能需倒車進場", "Free | 窄車道": "免費；車道較窄",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(parse_fee(raw), expected)

    def test_name_prefix_carries_fee_except_ban_marker(self):
        self.assertEqual(split_name("(平50/h|假60/h)福星社會住宅地下停車場"), ("福星社會住宅地下停車場", "平50/h|假60/h"))
        self.assertEqual(split_name("(禁止)嘟嘟房(西門漢口站)"), ("嘟嘟房(西門漢口站)", ""))
        self.assertEqual(split_name("松河街238號 重機專用格"), ("松河街238號 重機專用格", ""))

    def test_direction_arrows_do_not_hide_fee_prefix(self):
        mark = {"layer": "汽車費率", "name": "⇦⇨(30/h | 200/d)中林站 市民大道停車場", "description": "",
                "icon": "1538", "color": "7CB342", "line": False, "points": [(121.52, 25.04)]}
        spot = normalize(mark)
        self.assertEqual(spot["name"], "中林站 市民大道停車場")
        self.assertTrue(spot["fee_note"].startswith("每小時 30 元；每日 200 元"))
        self.assertIn("東西向皆可進入", spot["entrance_note"])
        self.assertEqual(entry_direction("⇦ (禁止)Times 台北地下街停車場"), ("(禁止)Times 台北地下街停車場", "入口方向：往西方向進入"))


class NormalizeTest(unittest.TestCase):
    def test_description_drops_links_images_credits_and_press_boilerplate(self):
        text = '<img src="x"/>機車道入場<br>https://maps.app.goo.gl/x<br>感謝 someone@PTT<br>---<br>停管處宣布試辦<br>有重機專用格'
        self.assertEqual(clean_text(text), ["機車道入場", "有重機專用格"])

    def test_off_street_layers_map_icons_to_zones(self):
        spot = normalize(mark("重機格/汽車費率", "(40/h)樂活公園地下停車場", icon="1633", description="汽車道入場<br>B2 有重機專用格三格<br>週末人多"))
        self.assertEqual(spot["space_type"], "offStreet")
        self.assertEqual(spot["parking_zones"], [{"name": "重機專用格", "access": "heavyOnly", "fee_note": "每小時 40 元"}])
        self.assertEqual(spot["fee_note"], "每小時 40 元（重機專用格比照汽車費率）")
        self.assertEqual(spot["entrance_note"], "走汽車車道")
        self.assertEqual(spot["parking_guide"], "重機專用格 3 格\n重機停放樓層：B2")
        self.assertEqual(spot["note"], "")  # 週末人多 is no vocabulary fact
        self.assertEqual(spot["facility_type"], "underground")
        self.assertIs(spot["heavy_allowed"], True)

    def test_banned_and_unverified_layers_do_not_claim_access(self):
        banned = normalize(mark("禁停重機", "(禁止)亞東醫院地下停車場", icon="1898", color="E65100"))
        self.assertIs(banned["heavy_allowed"], False)
        self.assertEqual(banned["fee_note"], "請依現場公告")
        unknown = normalize(mark("未確定", "(20/h)社子國小地下停車場", color="757575"))
        self.assertIsNone(unknown["heavy_allowed"])
        self.assertNotIn("access", unknown["parking_zones"][0])
        self.assertTrue(unknown["unconfirmed"])
        self.assertEqual(unknown["note"], "")  # the icon colour is no longer turned into a note (#275)

    def test_roadside_layer_variants(self):
        heavy = normalize(mark("路邊友善車格", "(30/4h)安和路重機專用格", icon="1644"))
        self.assertEqual((heavy["space_type"], heavy["facility_type"], heavy["scooter_allowed"]), ("heavyOnly", "roadside", False))
        shared = normalize(mark("路邊友善車格", "普通大型共用機車格", icon="1644", color="0288D1",
                                description="南港區三重路（西側），停車格在經貿二路106巷至新民街西側。"))
        self.assertEqual(shared["name"], "三重路 普大共用機車格")
        self.assertEqual(shared["road_segment"], "三重路（西側）經貿二路106巷至新民街西側")
        segment = normalize(mark("路邊友善車格", "過圳街31巷", icon="line", color="01579B", line=True))
        self.assertEqual((segment["space_type"], segment["road_segment"]), ("paidMotorcycle", "過圳街31巷"))
        self.assertAlmostEqual(segment["lat"], 25.001, places=5)
        timed = normalize(mark("路邊友善車格", "(Free - 平日夜間20-7 / 假日限定) 敦化北路199巷2弄 汽機車共用停車格", icon="1644", color="9C27B0"))
        self.assertEqual((timed["space_type"], timed["fee_note"]), ("car", "免費"))
        self.assertIn("平日夜間20-7", timed["special_rules"])

    def test_line_midpoint_is_halfway_along_its_length(self):
        self.assertEqual(midpoint([(121.5, 25.0)]), (121.5, 25.0))
        lng, lat = midpoint([(121.5, 25.0), (121.5, 25.002)])  # two vertices: not an endpoint
        self.assertAlmostEqual(lat, 25.001)
        lng, lat = midpoint([(121.5, 25.0), (121.5, 25.0001), (121.5, 25.0002), (121.5, 25.004)])  # uneven sampling
        self.assertAlmostEqual(lat, 25.002)

    def test_shops_and_district_policy_notes_are_not_spots(self):
        self.assertIsNone(normalize(mark("重機友善店家", "嵐天咖啡館", icon="1684")))
        self.assertIsNone(normalize(mark("路邊友善車格", "板橋區", icon="1502")))


class OfficialTest(unittest.TestCase):
    def test_twd97_conversion_matches_official_entrance(self):
        lat, lng = tm2_to_wgs84(302864.7812, 2771988.958)  # TPE0001, entrance 25.0552, 121.5242
        self.assertAlmostEqual(lat, 25.0552, places=3)
        self.assertAlmostEqual(lng, 121.5242, places=3)

    def test_matching_requires_name_evidence_not_only_proximity(self):
        spot = {"name": "大潤發中和店機車停車場", "lat": 25.0, "lng": 121.5}
        lots = [{"name": "迪卡儂中和停車場", "lat": 25.0001, "lng": 121.5, "motor": 10}]
        self.assertIsNone(match_lot(spot, lots))
        spot["name"] = "嘟嘟房僑安站"
        lots = [{"name": "僑安地下停車場", "lat": 25.0003, "lng": 121.5, "motor": 0}]
        self.assertEqual(match_lot(spot, lots)[1]["name"], "僑安地下停車場")
        spot["name"] = "臺北市洲子立體停車場"  # a city prefix is not part of the lot's name
        lots = [{"name": "洲子站", "lat": 25.0001, "lng": 121.5, "motor": 0}, {"name": "洲子立體停車場", "lat": 25.0002, "lng": 121.5, "motor": 0}]
        self.assertEqual(match_lot(spot, lots)[1]["name"], "洲子立體停車場")
        spot["name"] = "華泰名品城機車停車場（三期）"  # a generic official name far away is not the same lot
        self.assertIsNone(match_lot(spot, [{"name": "華泰名品城", "lat": 25.0045, "lng": 121.5, "motor": 100}]))
        spot["name"] = "台中勤美機車停車場"  # a motorcycle lot is not one with no motorcycle bays
        self.assertIsNone(match_lot(spot, [{"name": "臺中勤美洲際酒店停車場", "lat": 25.0005, "lng": 121.5, "motor": 0}]))
        spot["name"] = "新莊幸福立體停車場"  # a retail chain's lot is another business's facility
        self.assertIsNone(match_lot(spot, [{"name": "Times全聯新莊幸福東店停車場", "lat": 25.0005, "lng": 121.5, "motor": 0}]))
        spot["name"] = "城市車旅士林福德一站"  # two operators are two facilities
        self.assertIsNone(match_lot(spot, [{"name": "Times士林福德路第3", "lat": 25.0003, "lng": 121.5, "motor": 0}]))
        spot["name"] = "CITY PARKING 城市車旅停車場 大慶站"  # aliases of one operator still match
        self.assertEqual(match_lot(spot, [{"name": "城市車旅大慶停車場", "lat": 25.0001, "lng": 121.5, "motor": 0}])[1]["name"], "城市車旅大慶停車場")
        spot["name"] = "中山運動中心地下停車場"  # stated structures differ
        self.assertIsNone(match_lot(spot, [{"name": "中山運動中心旁臨時平面停車場", "lat": 25.0005, "lng": 121.5, "motor": 0}]))

    def test_lots_without_coordinates_match_by_name_within_district_only(self):
        register = [lot("KHH-停1", "嘟嘟房高雄美術館停車場", None, None, "美術館路", "每小時 20 元", district="鼓山區")]
        spot = {"name": "嘟嘟房停車場（高雄美術館站）", "lat": 22.65, "lng": 120.28, "district": "鼓山區",
                "note": "", "address": "", "fee_note": "", "parking_zones": [], "heavy_allowed": True, "city": "高雄市"}
        best = match_lot(spot, register)
        self.assertIsNone(best[2])
        entry = apply_official(spot, best[1], best[2], best[3], "高雄市一覽表")
        self.assertEqual((spot["lat"], spot["lng"]), (22.65, 120.28))
        self.assertIsNone(entry["distance_m"])
        spot["district"] = "三民區"
        self.assertIsNone(match_lot(spot, register))

    def test_official_address_gets_district_only_when_missing(self):
        def address(city, district, official):
            spot = {"name": "x", "city": city, "district": district, "note": "", "address": "", "fee_note": "",
                    "parking_zones": [], "heavy_allowed": True, "lat": 24.8, "lng": 120.9}
            apply_official(spot, lot("1", "x", 24.8, 120.9, official), 0, 1.0, "官方")
            return spot["address"]
        self.assertEqual(address("新竹市", "新竹市", "新竹市中央路229號"), "新竹市中央路229號")
        self.assertEqual(address("臺南市", "南區", "廣州里南區夏林路2號"), "臺南市廣州里南區夏林路2號")
        self.assertEqual(address("臺北市", "大安區", "嘉興街373號"), "臺北市大安區嘉興街373號")
        self.assertEqual(address("新竹縣", "竹北市", "新竹縣竹北市勝利二路2號"), "新竹縣竹北市勝利二路2號")
        self.assertEqual(address("新竹市", "東區", "300新竹市東區公竹路"), "新竹市東區公竹路")
        self.assertEqual(address("臺北市", "中正區", "台北市中正區信義路1段1號"), "臺北市中正區信義路1段1號")

    def test_taipei_pilot_adds_scooter_area_and_flags_conflicting_ban(self):
        spot = {"name": "忠信廣場地下停車場", "space_type": "offStreet", "heavy_allowed": False, "parking_zones": [], "special_rules": ""}
        pilot, changes = apply_taipei_rules(spot)
        self.assertEqual(pilot, "忠信地下停車場")
        self.assertEqual(spot["parking_zones"], [{"name": "機車區", "access": "scooterHeavy", "fee_note": f"大型重機{TAIPEI_PILOT[pilot]}"}])
        self.assertEqual(spot["special_rules"], PILOT_RULES)
        self.assertIsNone(spot["heavy_allowed"])
        self.assertTrue(any(change.startswith("待人工確認") for change in changes))
        roadside = {"name": "三重路 普大共用機車格", "space_type": "paidMotorcycle", "fee_note": "請依現場公告"}
        apply_taipei_rules(roadside)
        self.assertEqual(roadside["fee_note"], TAIPEI_ROADSIDE[0])

    def test_merge_treats_unknown_as_missing_not_conflict(self):
        def spot(heavy, zone):
            return {"heavy_allowed": heavy, "parking_zones": [{"name": zone}], "entrance_note": "", "parking_guide": "", "note": "", "special_rules": ""}
        kept = spot(None, "汽車區")
        self.assertEqual(merge(kept, spot(True, "機車區")), "")
        self.assertIs(kept["heavy_allowed"], True)
        self.assertEqual([z["name"] for z in kept["parking_zones"]], ["汽車區", "機車區"])
        self.assertTrue(merge(kept, spot(False, "機車區")).startswith("待人工確認"))
        self.assertIsNone(kept["heavy_allowed"])
        self.assertEqual(merge(kept, spot(True, "重機專用格")), "")  # a later report cannot clear the conflict
        self.assertIsNone(kept["heavy_allowed"])
        promoted = spot(True, "汽車區")  # an official placemark promoted over the conflicted record keeps the conflict
        self.assertEqual(merge(promoted, kept), "")
        self.assertIsNone(promoted["heavy_allowed"])
        self.assertTrue(promoted["heavy_conflict"])


class OfficialSourceTest(unittest.TestCase):
    def test_hsinchu_intermediate_must_match_pinned_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "twca_ssl_2023.crt").write_bytes(b"not the pinned certificate")
            with self.assertRaises(ValueError):
                hccg_context(Path(directory))

    def test_a_source_without_its_header_row_fails_alone(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict("import_mymaps.LOADERS", {}, clear=True):
            import_mymaps.LOADERS["高雄市"] = lambda cache, refresh: next(iter([]))
            import_mymaps.LOADERS["新竹市"] = lambda cache, refresh: [lot("HSZ001", "府後地下停車場", 24.8, 120.97)]
            lots, failed = official_lots(Path(directory), tdx_env=Path(directory) / "missing.env")
        self.assertEqual(lots["高雄市"], [])
        self.assertEqual(len(lots["新竹市"]), 1)
        self.assertTrue(failed[0].startswith("高雄市：StopIteration"))

    def test_kaohsiung_private_register_is_read_by_header_names(self):
        title = "高雄市合格登記路外民營停車場一覽表"
        header = {"登記證號": "Column9", "停車場名稱": "Column1", "行政區": "Column2", "停車場位置": "Column3", "型式": "Column4",
                  "機車": "Column5", "收費標準\n(僅供參考實際以現場公告為主)": "Column6"}
        rows = [{title: "三民區", **{v: "" for v in header.values()}},
                {title: "", **{v: k for k, v in header.items()}},
                {title: "", "Column9": "停2554", "Column1": "義大大昌醫院停車場", "Column2": "三民區", "Column3": "大昌一路305號",
                 "Column4": "建物立體", "Column5": "12", "Column6": "每半小時15元"}]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "kcg.json").write_text(json.dumps({"data": []}))
            Path(directory, "kcg_private.json").write_text(json.dumps({"data": rows}, ensure_ascii=False))
            [private] = kaohsiung(Path(directory), False)
        self.assertEqual((private["id"], private["name"], private["district"], private["fee"], private["motor"]),
                         ("KHH-停2554", "義大大昌醫院停車場", "三民區", "每半小時15元", 12))


class FacilityMergeTest(unittest.TestCase):
    def test_unmatched_zone_pins_of_one_facility_share_a_key(self):
        def pin(name, lat, kind="offStreet"):
            return {"name": name, "lat": lat, "lng": 121.5, "space_type": kind}
        seen = {"k": (pin("大魯閣新時代購物中心", 25.0), {"layer": "汽車費率"})}
        self.assertEqual(facility_key(pin("大魯閣新時代購物中心", 25.0003), seen), "k")  # about 33 m apart
        self.assertIsNone(facility_key(pin("大魯閣新時代購物中心", 25.01), seen))  # about 1.1 km apart
        self.assertIsNone(facility_key(pin("另一間購物中心", 25.0003), seen))
        seen["w"] = (pin("天母西側停車場", 25.2), {"layer": "汽車費率"})
        self.assertIsNone(facility_key(pin("天母東側停車場", 25.2003), seen))  # sibling lots stay apart
        self.assertIsNone(facility_key(pin("大魯閣新時代購物中心", 25.0003, "paidMotorcycle"), seen))
        seen["k"][1]["official_id"] = "TPE1"  # matched facilities merge by their official id instead
        self.assertIsNone(facility_key(pin("大魯閣新時代購物中心", 25.0003), seen))

    def test_report_cells_escape_pipes(self):
        self.assertEqual(cell("(平40/h | 假50/h)松山\n車站"), "(平40/h \\| 假50/h)松山 車站")


class LocateTest(unittest.TestCase):
    def test_lookup_retries_then_reports_failure_without_caching_it(self):
        with tempfile.TemporaryDirectory() as directory, patch("import_mymaps.time.sleep"), \
                patch("import_mymaps.urllib.request.urlopen", side_effect=TimeoutError("timed out")) as urlopen:
            cache, cache_file = {}, Path(directory) / "nlsc.json"
            self.assertIsNone(locate({"lat": 25.0, "lng": 121.5}, cache_file, cache))
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual(cache, {})

    def test_a_transient_failure_is_retried(self):
        ok = unittest.mock.MagicMock()
        ok.__enter__.return_value.read.return_value = "<r><ctyName>臺北市</ctyName><townName>大安區</townName></r>".encode()
        with tempfile.TemporaryDirectory() as directory, patch("import_mymaps.time.sleep"), \
                patch("import_mymaps.urllib.request.urlopen", side_effect=[TimeoutError("timed out"), ok]):
            cache = {}
            self.assertEqual(locate({"lat": 25.0, "lng": 121.5}, Path(directory) / "nlsc.json", cache), ["臺北市", "大安區"])
        self.assertEqual(len(cache), 1)


class TdxCredentialTest(unittest.TestCase):
    def test_environment_overrides_env_file_and_missing_values_skip_tdx(self):
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / ".env"
            env.write_text("TDX_MODE=fixture\nTDX_CLIENT_ID=file-id\nTDX_CLIENT_SECRET=file-secret\n")
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(tdx_credentials(env), ("file-id", "file-secret"))
            with patch.dict(os.environ, {"TDX_CLIENT_ID": "env-id", "TDX_CLIENT_SECRET": "env-secret"}, clear=True):
                self.assertEqual(tdx_credentials(env), ("env-id", "env-secret"))
            env.write_text("TDX_CLIENT_ID=\nTDX_CLIENT_SECRET=\n")
            with patch.dict(os.environ, {}, clear=True):
                self.assertIsNone(tdx_credentials(env))
                self.assertIsNone(tdx_credentials(Path(directory) / "missing.env"))


class TdxFailureTest(unittest.TestCase):
    def test_one_city_failure_does_not_drop_later_cities(self):
        token = unittest.mock.MagicMock()
        token.__enter__.return_value.read.return_value = b'{"access_token": "t"}'

        def rows(_, kind, city, *__):
            if city == "Taipei":
                raise TimeoutError("timed out")
            if kind == "CarPark":
                return [{"CarParkID": "1", "CarParkName": {"Zh_tw": "某停車場"}, "CarParkPosition": {"PositionLat": 24.8, "PositionLon": 120.9}}]
            return [{"CarParkID": "1", "Spaces": [{"SpaceType": 2, "NumberOfSpaces": 5}]}]

        with patch("import_mymaps.urllib.request.urlopen", return_value=token), patch("import_mymaps.tdx_rows", side_effect=rows):
            lots, failed = tdx_lots(Path("unused"), False, ("id", "secret"))
        self.assertEqual(failed, ["TDX 臺北市：TimeoutError"])
        self.assertEqual(lots["新竹市"][0]["motor"], 5)
        self.assertNotIn("臺北市", lots)


class OfficialSpotTest(unittest.TestCase):
    LOT = {"id": "HSZ001", "name": "府後地下停車場", "lat": 24.80726, "lng": 120.969783, "address": "新竹市北區府後街42號",
           "fee": "汽車：20元/H", "summary": "", "motor": 12, "heavy": 0, "city": "新竹市", "district": "北區",
           "source": "新竹市公有停車場相關資訊", "url": "https://data.gov.tw/dataset/67771"}

    def test_community_heavy_claims_never_become_official_access(self):
        spot = {"city": "新竹市", "district": "北區", "lat": 24.8073, "lng": 120.9698, "heavy_allowed": True,
                "note": "車道較窄\n已比對新竹市公有停車場相關資訊（HSZ001）", "address": "", "entrance_note": "走機車車道", "parking_guide": "", "facility_type": None,
                "parking_zones": [{"name": "汽車區", "access": "heavyCar", "fee_note": "每小時 20 元"}]}
        official = official_spot(self.LOT, spot, None, {}, "2026-10-17")
        self.assertEqual((official["source"], official["status"], official["source_name"]), ("official", "confirmed", "新竹市政府"))
        self.assertIsNone(official["heavy_allowed"])
        self.assertIs(official["scooter_allowed"], True)
        self.assertEqual(official["parking_zones"], [])
        self.assertEqual(official["note"], "社群補充（未經官方查核）：大型重機可停；停放區域：汽車區（每小時 20 元）；車道較窄\n"
                                           "已比對新竹市公有停車場相關資訊（HSZ001）")
        self.assertEqual(official["license_note"], "政府資料開放授權條款第 1 版；社群協力資料，經核驗後只收錄事實")
        self.assertTrue(official["entrance_note"].startswith("社群補充（未經官方查核）"))
        self.assertEqual((official["lat"], official["lng"]), (24.8073, 120.9698))

    def test_official_heavy_evidence_sets_access(self):
        lot = self.LOT | {"city": "臺北市", "heavy": 4, "source": "臺北市停車場資訊（臺北市停車管理工程處）"}
        official = official_spot(lot, None, "樂活公園地下停車場", {}, "2026-10-17")
        self.assertIs(official["heavy_allowed"], True)
        self.assertEqual([z["access"] for z in official["parking_zones"]], ["heavyOnly", "scooterHeavy"])
        self.assertEqual(official["source_name"], "臺北市政府")

    def test_additions_need_motorcycle_bays_or_heavy_evidence_and_skip_tdx_repeats(self):
        own = self.LOT | {"id": "A", "source": "臺南市路外停車場動態資訊（臺南市政府交通局）"}
        cars = own | {"id": "B", "motor": 0, "name": "汽車場", "lat": 25.0}
        repeat = own | {"id": "TDX-A", "source": TDX_SOURCE}
        tdx_only = own | {"id": "TDX-C", "source": TDX_SOURCE, "name": "另一停車場", "lat": 23.0}
        added = [lot["id"] for lot, _ in official_additions({"臺南市": [own, cars, repeat, tdx_only]}, set())]
        self.assertEqual(added, ["A", "TDX-C"])
        placed = [{"name": "另一停車場", "lat": 23.0, "lng": self.LOT["lng"], "city": "臺南市", "scooter_total": 3,
                   "source_id": "A"}]
        self.assertEqual([lot["id"] for lot, _ in official_additions({"臺南市": [tdx_only]}, set(), placed)], [])

    def test_tdx_repeat_named_differently_is_skipped_by_place_and_bays(self):
        own = self.LOT | {"id": "A", "motor": 315, "name": "柳川機車停車場", "source": "臺中市路外剩餘車位（臺中市政府交通局）"}
        repeat = own | {"id": "TDX-A", "name": "交通局柳川P", "motor": 312, "source": TDX_SOURCE}
        other = repeat | {"id": "TDX-B", "motor": 40}
        added = [lot["id"] for lot, _ in official_additions({"臺中市": [own, repeat, other]}, set())]
        self.assertEqual(added, ["A", "TDX-B"])
        # About 50 m apart: only an exact, sizeable bay count still identifies the lot.
        shifted = repeat | {"id": "TDX-E", "lat": own["lat"] + 0.00045, "motor": 315}
        nearly = shifted | {"id": "TDX-F", "motor": 312}
        added = [lot["id"] for lot, _ in official_additions({"臺中市": [own, shifted, nearly]}, set())]
        self.assertEqual(added, ["A", "TDX-F"])
        # Taichung TDX names match the city lot once district and agency are dropped, bay counts aside.
        named = own | {"id": "TDX-D", "name": "西區-交通局-柳川機車P", "motor": 200, "source": TDX_SOURCE}
        self.assertEqual([lot["id"] for lot, _ in official_additions({"臺中市": [own, named]}, set())], ["A"])
        self.assertEqual(display_name(named, "臺中市"), "柳川機車停車場")
        self.assertEqual(display_name(named, "臺南市"), "西區-交通局-柳川機車P")
        # A map spot verified against TDX already stands for the city lot at the same place.
        via_tdx = [{"name": "柳川機車停車場", "lat": own["lat"], "lng": own["lng"], "city": "臺中市", "scooter_total": 312,
                    "source_id": "TDX-A"}]
        self.assertEqual([lot["id"] for lot, _ in official_additions({"臺中市": [own]}, set(), via_tdx)], [])
        via_city = [via_tdx[0] | {"source_id": "TXG1"}]
        self.assertEqual([lot["id"] for lot, _ in official_additions({"臺中市": [own]}, set(), via_city)], ["A"])

    def test_taichung_names_drop_district_and_agency_but_keep_floor_note(self):
        self.assertEqual(taichung_name("西區-交通局-柳川機車P"), "柳川機車停車場")
        self.assertEqual(taichung_name("西屯區-民營-城市車旅-玉門站P"), "城市車旅 玉門站停車場")
        self.assertEqual(taichung_name("烏日區-臺鐵-大車河台鐵新烏日-地下P"), "大車河台鐵新烏日 地下停車場")
        self.assertEqual(taichung_name("中區-交通局-自由一期立體P(B1F-6F)"), "自由一期立體停車場(B1F-6F)")
        self.assertEqual(taichung_name("Times萬華運動中心"), "Times萬華運動中心")


class ImportableTest(unittest.TestCase):
    """The JSON must pass the Admin Web import page's checks (admin_import_plan in 202610260250_admin_import.sql)."""
    COMMUNITY = {"id": "00000000-0000-4000-8000-000000000009", "name": "x'y", "city": "臺北市", "district": "大安區", "source": "import",
                 "space_type": "offStreet", "fee_note": "請依現場公告", "note": None, "heavy_allowed": None, "scooter_allowed": True,
                 "scooter_total": None, "lat": 25.0, "lng": 121.5, "source_name": "社群回報整理", "source_url": "https://a",
                 "license_note": "", "parking_zones": [{"name": "機車區"}]}
    OFFICIAL = COMMUNITY | {"id": "official:00000000-0000-4000-8000-000000000009", "source": "official", "source_id": "TPE1",
                            "source_name": "臺北市政府", "scooter_total": 12}

    def test_the_tool_output_shape_is_accepted(self):
        self.assertEqual(importable(self.COMMUNITY), "")
        self.assertEqual(importable(self.OFFICIAL), "")
        # Keys the page does not write (status, updated_at…) and missing optional columns are fine.
        self.assertEqual(importable(self.OFFICIAL | {"status": "confirmed", "updated_at": "2026-10-17T00:00:00Z", "available": None}), "")
        self.assertEqual(importable({k: v for k, v in self.COMMUNITY.items() if k not in ("note", "parking_zones", "license_note")}), "")

    def test_refusals_follow_the_import_page(self):
        cases = [
            (self.COMMUNITY | {"id": "TPE0001"}, "沒有可辨識的 id"),
            ({k: v for k, v in self.COMMUNITY.items() if k != "id"}, "沒有可辨識的 id"),
            (self.COMMUNITY | {"source": "official"}, "來源與 id 不符"),
            (self.OFFICIAL | {"source": "import"}, "來源與 id 不符"),
            (self.COMMUNITY | {"lat": "25.0"}, "欄位型別錯誤：lat"),
            (self.COMMUNITY | {"scooter_total": True}, "欄位型別錯誤：scooter_total"),
            (self.COMMUNITY | {"parking_zones": "機車區"}, "欄位型別錯誤：parking_zones"),
            (self.COMMUNITY | {"name": " "}, "名稱需為 1–100 字"),
            (self.COMMUNITY | {"name": "長" * 101}, "名稱需為 1–100 字"),
            (self.COMMUNITY | {"lat": 35.0}, "座標不在台灣範圍內"),
            ({k: v for k, v in self.COMMUNITY.items() if k != "lng"}, "座標不在台灣範圍內"),
            (self.COMMUNITY | {"city": ""}, "缺少縣市"),
            (self.OFFICIAL | {"source_url": "http://a"}, "官方點需要資料來源與 https 官方資料網址"),
            (self.OFFICIAL | {"source_name": ""}, "官方點需要資料來源與 https 官方資料網址"),
        ]
        for spot, reason in cases:
            with self.subTest(reason=reason):
                self.assertTrue(importable(spot).startswith(reason), importable(spot))
        # A community spot needs no https source; an official one does.
        self.assertEqual(importable(self.COMMUNITY | {"source_url": "http://a"}), "")

    def test_a_repeated_id_is_refused_once_per_file(self):
        self.assertEqual(unimportable([self.COMMUNITY, self.OFFICIAL]), [])
        problems = unimportable([self.COMMUNITY, self.COMMUNITY | {"name": "again"}, self.OFFICIAL | {"city": ""}])
        self.assertEqual(problems, [(1, "again", "檔案中重複的 id"), (2, "x'y", "缺少縣市")])


class MainTest(unittest.TestCase):
    def run_main(self, official, community, *extra):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            argv = ["import_mymaps.py", "--mid", "m", "--kml", str(root / "m.kml"), "--cache", str(root / "cache"),
                    "--output", str(root / "community"), "--official-output", str(root / "official"), "--date", "2026-10-26", *extra]
            out, err = io.StringIO(), io.StringIO()
            with patch.object(sys, "argv", argv), patch("import_mymaps.build", return_value=(official, community, [], [], [], {})), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    import_mymaps.main()
                    code = 0
                except SystemExit as exit:
                    code = exit.code
            written = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
            return code, out.getvalue() + err.getvalue(), written

    def test_sql_output_is_gone(self):
        self.assertFalse(hasattr(import_mymaps, "official_sql") or hasattr(import_mymaps, "sql"))
        code, output, written = self.run_main([], [ImportableTest.COMMUNITY], "--sql-owner", "10000000-0000-4000-8000-000000000001")
        self.assertEqual(code, 2)
        self.assertIn("--sql-owner", output)
        self.assertEqual(written, set())
        code, output, written = self.run_main([ImportableTest.OFFICIAL], [ImportableTest.COMMUNITY])
        self.assertEqual(code, 0)
        self.assertNotIn("sql", output.lower())
        self.assertEqual(written, {"official/spots.json", "community/spots.json", "community/verification.json", "community/REPORT.md"})

    def test_a_spot_the_import_page_would_refuse_fails_the_run_after_writing(self):
        code, output, written = self.run_main([ImportableTest.OFFICIAL | {"source_url": "http://a"}], [ImportableTest.COMMUNITY])
        self.assertEqual(code, 1)
        self.assertIn("第 1 筆「x'y」管理站無法匯入：官方點需要資料來源與 https 官方資料網址", output)
        self.assertIn("official/spots.json", written)


class ImportedDataTest(unittest.TestCase):
    ENUMS = {
        "space_type": {"paidMotorcycle", "freeMotorcycle", "heavyOnly", "car", "offStreet"},
        "facility_type": {"multiStorey", "underground", "surface", "roadside"},
        "parking_access": {"scooterOnly", "scooterHeavy", "heavyCar", "noMotorcycle", "heavyOnly"},
    }

    def check_common(self, s):
        self.assertTrue(1 <= len(s["name"]) <= 100 and len(s["fee_note"]) <= 200 and len(s["note"]) <= 500)
        self.assertTrue(20 <= s["lat"] <= 27 and 118 <= s["lng"] <= 123 and s["city"] and s["district"])
        self.assertTrue(s["source_url"].startswith("https://"))
        for key, values in self.ENUMS.items():
            if key in s:
                self.assertIn(s[key], values)
        for zone in s.get("parking_zones", []):
            self.assertTrue(zone["name"])
            if "access" in zone:
                self.assertIn(zone["access"], self.ENUMS["parking_access"])

    def test_committed_files_pass_the_import_page_checks(self):
        for path in (DATA, OFFICIAL_DATA):
            with self.subTest(file=path.name):
                self.assertEqual(unimportable(json.loads(path.read_text())), [])

    def test_community_spots_are_pending_community_compilations(self):
        spots = json.loads(DATA.read_text())
        self.assertGreater(len(spots), 300)
        self.assertEqual(len({s["id"] for s in spots}), len(spots))
        for s in spots:
            with self.subTest(spot=s["name"]):
                self.assertEqual((s["source"], s["status"], s["source_name"]), ("import", "pending", "社群回報整理"))
                self.check_common(s)

    def test_official_spots_fit_the_official_table(self):
        spots = json.loads(OFFICIAL_DATA.read_text())
        self.assertGreater(len(spots), 1000)
        self.assertEqual(len({s["id"] for s in spots}), len(spots))
        self.assertEqual(len({s["source_id"] for s in spots}), len(spots))
        for s in spots:
            with self.subTest(spot=s["name"]):
                self.assertEqual((s["source"], s["status"]), ("official", "confirmed"))
                self.assertTrue(s["id"].startswith("official:") and s["source_name"].endswith("政府"))
                self.assertIn(s["heavy_allowed"], (True, None))  # official data never states a ban here
                self.assertTrue(s["scooter_allowed"] or s["heavy_allowed"] or s["note"])
                self.assertLessEqual(len(s.get("address", "")), 200)
                self.check_common(s)


if __name__ == "__main__":
    unittest.main()
