"""Check My Maps normalization rules and the committed import against database limits."""
import json
from pathlib import Path
import unittest

from import_mymaps import (
    PILOT_RULES, TAIPEI_PILOT, TAIPEI_ROADSIDE, apply_official, apply_taipei_rules, clean_text, lot, match_lot, merge,
    normalize, parse_fee, split_name, tm2_to_wgs84,
)

DATA = Path(__file__).resolve().parent.parent / "data/imports/google-mymaps/spots.json"


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
            "40/h - 管理員": "每小時 40 元；需管理員協助",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(parse_fee(raw), expected)

    def test_name_prefix_carries_fee_except_ban_marker(self):
        self.assertEqual(split_name("(平50/h|假60/h)福星社會住宅地下停車場"), ("福星社會住宅地下停車場", "平50/h|假60/h"))
        self.assertEqual(split_name("(禁止)嘟嘟房(西門漢口站)"), ("嘟嘟房(西門漢口站)", ""))
        self.assertEqual(split_name("松河街238號 重機專用格"), ("松河街238號 重機專用格", ""))


class NormalizeTest(unittest.TestCase):
    def test_description_drops_links_images_credits_and_press_boilerplate(self):
        text = '<img src="x"/>機車道入場<br>https://maps.app.goo.gl/x<br>感謝 someone@PTT<br>---<br>停管處宣布試辦<br>有重機專用格'
        self.assertEqual(clean_text(text), ["機車道入場", "有重機專用格"])

    def test_off_street_layers_map_icons_to_zones(self):
        spot = normalize(mark("重機格/汽車費率", "(40/h)樂活公園地下停車場", icon="1633", description="汽車道入場<br>B2 有重機專用格三格<br>週末人多"))
        self.assertEqual(spot["space_type"], "offStreet")
        self.assertEqual(spot["parking_zones"], [{"name": "重機專用格", "access": "heavyOnly", "fee_note": "每小時 40 元"}])
        self.assertEqual(spot["fee_note"], "每小時 40 元（重機專用格比照汽車費率）")
        self.assertEqual(spot["entrance_note"], "汽車道入場")
        self.assertEqual(spot["parking_guide"], "B2 有重機專用格三格")
        self.assertEqual(spot["note"], "週末人多")
        self.assertEqual(spot["facility_type"], "underground")
        self.assertIs(spot["heavy_allowed"], True)

    def test_banned_and_unverified_layers_do_not_claim_access(self):
        banned = normalize(mark("禁停重機", "(禁止)亞東醫院地下停車場", icon="1898", color="E65100"))
        self.assertIs(banned["heavy_allowed"], False)
        self.assertEqual(banned["fee_note"], "請依現場公告")
        unknown = normalize(mark("未確定", "(20/h)社子國小地下停車場", color="757575"))
        self.assertIsNone(unknown["heavy_allowed"])
        self.assertNotIn("access", unknown["parking_zones"][0])
        self.assertIn("未確認", unknown["note"])

    def test_roadside_layer_variants(self):
        heavy = normalize(mark("路邊友善車格", "(30/4h)安和路重機專用格", icon="1644"))
        self.assertEqual((heavy["space_type"], heavy["facility_type"], heavy["scooter_allowed"]), ("heavyOnly", "roadside", False))
        shared = normalize(mark("路邊友善車格", "普通大型共用機車格", icon="1644", color="0288D1",
                                description="南港區三重路（西側），停車格在經貿二路106巷至新民街西側。"))
        self.assertEqual(shared["name"], "三重路 普大共用機車格")
        self.assertEqual(shared["road_segment"], "三重路（西側）經貿二路106巷至新民街西側")
        segment = normalize(mark("路邊友善車格", "過圳街31巷", icon="line", color="01579B", line=True))
        self.assertEqual((segment["space_type"], segment["road_segment"], segment["lat"]), ("paidMotorcycle", "過圳街31巷", 25.001))
        timed = normalize(mark("路邊友善車格", "(Free - 平日夜間20-7 / 假日限定) 敦化北路199巷2弄 汽機車共用停車格", icon="1644", color="9C27B0"))
        self.assertEqual((timed["space_type"], timed["fee_note"]), ("car", "免費"))
        self.assertIn("平日夜間20-7", timed["special_rules"])

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


class ImportedDataTest(unittest.TestCase):
    def test_committed_spots_fit_project_schema(self):
        spots = json.loads(DATA.read_text())
        self.assertGreater(len(spots), 1000)
        self.assertEqual(len({s["id"] for s in spots}), len(spots))
        enums = {
            "space_type": {"paidMotorcycle", "freeMotorcycle", "heavyOnly", "car", "offStreet"},
            "facility_type": {"multiStorey", "underground", "surface", "roadside"},
            "parking_access": {"scooterOnly", "scooterHeavy", "heavyCar", "noMotorcycle", "heavyOnly"},
        }
        for s in spots:
            with self.subTest(spot=s["name"]):
                self.assertEqual((s["source"], s["status"]), ("import", "pending"))
                self.assertTrue(1 <= len(s["name"]) <= 100 and len(s["fee_note"]) <= 200 and len(s["note"]) <= 500)
                self.assertTrue(20 <= s["lat"] <= 27 and 118 <= s["lng"] <= 123 and s["city"] and s["district"])
                self.assertTrue(s["source_url"].startswith("https://"))
                for key, values in enums.items():
                    if key in s:
                        self.assertIn(s[key], values)
                for zone in s.get("parking_zones", []):
                    self.assertTrue(zone["name"])
                    if "access" in zone:
                        self.assertIn(zone["access"], enums["parking_access"])


if __name__ == "__main__":
    unittest.main()
