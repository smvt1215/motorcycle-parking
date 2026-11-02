"""The My Maps compilation keeps only verified facts in fixed words (#275)."""
import json
import re
from pathlib import Path
import unittest

from import_mymaps import normalize, official_spot
from mymaps_facts import (
    COMMUNITY, LICENSE, OFFICIAL_LICENSE, OPEN_DATA, facts, fact_field, is_fact, kept_template, license_note, scrub_fee_text,
    scrub_spot, scrub_summary_fees, split_lines,
)

ROOT = Path(__file__).resolve().parent.parent
COMMUNITY_DATA = ROOT / "data/imports/google-mymaps/spots.json"
OFFICIAL_DATA = ROOT / "data/imports/official/spots.json"
TEXT = ("note", "entrance_note", "parking_guide", "special_rules")


def allowed(field, line, official):
    """Whether a stored line is ours: a vocabulary phrase, a tool template, or the community label."""
    if is_fact(line) or kept_template(field, line):
        return True
    if official and field in ("entrance_note", "parking_guide") and line == COMMUNITY:
        return True
    if official and field == "note" and line.startswith(COMMUNITY):
        return True  # claims; checked part by part in the test below
    return False


class VocabularyTest(unittest.TestCase):
    def test_short_fact_lines_become_fixed_phrases(self):
        cases = {
            "按鈕取票": {"entrance_note": ["按鈕取票"]},
            "機車區無柵欄": {"entrance_note": ["無柵欄"]},
            "有六格重機專用格": {"parking_guide": ["重機專用格 6 格"]},
            "專用2 格 或以上": {"parking_guide": ["重機專用格 2 格以上"]},
            "後牌辨析": {"entrance_note": ["後車牌辨識"]},
            "推車吧少年 僅有前牌辨識": {"entrance_note": ["只辨識前車牌"]},
            "汽車費率、無後方辨識": {"entrance_note": ["無後車牌辨識"]},
            "汽車道按鈴請人員協助進入": {"entrance_note": ["需按鈴或請管理員協助", "走汽車車道"]},
            "無出入口管制": {"entrance_note": ["無柵欄"]},
            "機車, B1有大重專用格6格": {"parking_guide": ["重機專用格 6 格", "重機停放樓層：B1"]},
            "消費50元折1小時 跟店員拿代幣": {"entrance_note": ["需投幣或取代幣"], "note": ["消費可折抵停車費"]},
            "沒看到禁止重機符號": {"note": ["現場未見禁止大型重機標示"]},
            "2024年9月起禁止大型重機停放": {"note": ["有禁止大型重機停放的回報"]},
            "半小時離場免費": {"note": ["前 30 分鐘免費"]},
            # A negation before the area, and two areas in one line (review on #287).
            "重機只能停 B3 汽車區，不可停機車區": {"parking_guide": ["可停汽車格", "重機停放樓層：B3", "機車區禁止大型重機"]},
            "後排辨識、有專用格，不可停汽車格": {"entrance_note": ["後車牌辨識"], "parking_guide": ["有重機專用格", "汽車區禁止大型重機"]},
            "禁停機車格，只能停汽車格": {"parking_guide": ["機車區禁止大型重機", "可停汽車格"]},
            # A sign not seen is no ban; another vehicle's bays are not heavy-bike bays (review on #287).
            "旁邊機車道未標示禁止重機": {"note": ["現場未見禁止大型重機標示"]},
            "地下二樓有收費機車專用格2格、": {},
            "重機專用格2格，機車專用格30格": {"parking_guide": ["重機專用格 2 格"]},
            # #298: no cash is no staff, a warning is no instruction, guesses are no facts.
            "汽車費率 30h,半小時計費 鍵盤輸入 無現金繳費": {"entrance_note": ["鍵盤輸入車號"]},
            "現金繳費": {},
            "人工收費，露天停車場。": {"entrance_note": ["人工繳費"]},
            "設計不良，按鈕處在斜坡上，有倒車的危險": {"note": ["進出有斜坡"]},
            "汽車費率 20h 倒退嚕": {"entrance_note": ["可能需倒車進場"]},
            "只有前車牌辨識 必須倒車入場出場": {"entrance_note": ["只辨識前車牌", "可能需倒車進場"]},
            "這邊忘記是後牌辨識還是悠遊卡進出": {},
            "重機後牌辨識似乎沒啟用，通常要管理員才能進": {},
            # Advice is no ban, and no permission either.
            "建議不要停汽車格": {},
            # A floor only where the bike parks now (review on #287).
            "*原B3/B4重機停車區將於114年10月24日起調整至B2樓層-重機區": {"parking_guide": ["有重機專用格"]},
            "如有問題，請洽B3管理室": {},
            "重機進入後到B1登記車號，停汽車車位": {"parking_guide": ["可停汽車格"]},
            "2025/10/24 開始試辦停至 B2 重機停車區": {"parking_guide": ["有重機專用格", "重機停放樓層：B2"]},
        }
        for line, expected in cases.items():
            with self.subTest(line=line):
                found = facts([line])
                self.assertEqual({k: v for k, v in found.items() if v}, expected)

    def test_other_lines_are_dropped_without_a_trace(self):
        for line in ("猴子很多東西要收好", "2024/04更新", "勇者可以挑戰機車區", "***感謝Ding",
                     "為提升路邊停車空間使用效率，台中市政府自115年起試辦",
                     "不確定是否有重機專用格 但是大型停車場 我都直接停汽車格", "理論上可停"):
            with self.subTest(line=line):
                self.assertEqual(facts([line]), {"note": [], "entrance_note": [], "parking_guide": []})

    def test_a_bay_count_replaces_the_bare_claim(self):
        self.assertEqual(facts(["有重機專用格", "專用格四格"])["parking_guide"], ["重機專用格 4 格"])

    def test_phrases_are_their_own_facts(self):
        for phrase in ("後車牌辨識", "只辨識前車牌", "重機專用格 3 格以上", "前 15 分鐘免費", "重機停放樓層：B2"):
            with self.subTest(phrase=phrase):
                field = fact_field(phrase)
                self.assertTrue(field)
                self.assertEqual(facts([phrase])[field], [phrase])


class FeeTextTest(unittest.TestCase):
    def test_fragments_keep_only_fixed_words(self):
        cases = {
            "免費；需按鈴（大型重機停汽車區）": "免費；需按鈴或請管理員協助（大型重機停汽車區）",
            "每小時 20 元；B2限悠遊卡（大型重機比照汽車費率）": "每小時 20 元；悠遊卡進出（大型重機比照汽車費率）",
            "平日每小時 20 元；假日每小時 40 元-後牌": "平日每小時 20 元；假日每小時 40 元；後車牌辨識",
            "每小時 60 元左車道進": "每小時 60 元",
            "每日 60 元起可能要留鑰匙（大型重機另訂費率）": "每日 60 元（大型重機另訂費率）",
            "每小時 200 元；消費折抵；人工註記": "每小時 200 元；消費可折抵停車費",
            "營業時間": "請依現場公告",
            "每日 30 元；電子票證每日 20 元": "每日 30 元；每日 20 元；悠遊卡進出",
            "每小時 30 元-按鈕": "每小時 30 元；按鈕取票",
            "請依現場公告": "請依現場公告",
            "平日每小時 30 元；假日每小時 50 元": "平日每小時 30 元；假日每小時 50 元",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(scrub_fee_text(text), expected)
                self.assertEqual(scrub_fee_text(expected), expected)

    def test_the_taipei_roadside_sentence_is_ours(self):
        text = "大型重機依路段收費方式：計次每次 40 元；計時每小時 20 元、當日上限 100 元；限時格首 20 分鐘 0 元（臺北市 115/10/6 起，可斜停 2 格）"
        self.assertEqual(scrub_fee_text(text), text)

    def test_official_summary_fees(self):
        note = f"{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；倒退掃牌）、重機專用格\n已比對X（1）"
        self.assertEqual(scrub_summary_fees(note), f"{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；可能需倒車進場）、重機專用格\n已比對X（1）")


class ScrubSpotTest(unittest.TestCase):
    def test_community_spot(self):
        old = {
            "note": "來源標示為特殊收費或管理方式\n消費50元折1小時 跟店員拿代幣\n猴子很多",
            "entrance_note": "來源標示：往西方向進入（⇦）\n來源標示進出場需注意（可能無後車牌辨識，需按鈴或請管理員協助）\n機車區無柵欄",
            "parking_guide": "露天重機專用格\n勇者可以挑戰機車區",
            "special_rules": "來源回報禁止大型重機停放\n一～五 07～09禁停大重機",
        }
        self.assertEqual(scrub_spot(old, official=False), {
            "note": "消費可折抵停車費",
            "entrance_note": "入口方向：往西方向進入\n需投幣或取代幣\n無柵欄",
            "parking_guide": "有重機專用格",
            "special_rules": "來源回報禁止大型重機停放",
        })

    def test_timed_shared_bays_keep_their_window(self):
        self.assertEqual(scrub_spot({"special_rules": "20/d - 平日夜間18-8 / 假日限定"}, official=False)["special_rules"],
                         "限時開放：平日夜間18-8 / 假日限定")

    def test_official_spot(self):
        old = {
            "note": f"{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元）\n來源原名稱：綠川東街14號(*收費亭 不是times)\n"
                    "來源標示為未確認資訊\n用餐住宿比照汽車折抵\n已比對臺北市停車場資訊（TPE0997）",
            "entrance_note": f"{COMMUNITY}\n汽車費率 20h 後牌辨析 / 慢慢都開始改成後",
            "parking_guide": f"{COMMUNITY}\n先前已問過客服人員，機車停車場是",
            "special_rules": "臺北市路外停車場試辦大型重機停放機車區（各期 6 個月）：依現場標誌斜停",
        }
        self.assertEqual(scrub_spot(old, official=True), {
            "note": f"{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元）；消費可折抵停車費\n已比對臺北市停車場資訊（TPE0997）",
            "entrance_note": f"{COMMUNITY}\n後車牌辨識",
            "parking_guide": "",  # only the label was left
            "special_rules": old["special_rules"],
        })

    def test_scrubbing_twice_changes_nothing(self):
        for path, official in ((COMMUNITY_DATA, False), (OFFICIAL_DATA, True)):
            for spot in json.loads(path.read_text()):
                once = scrub_spot(spot, official)
                with self.subTest(spot=spot["id"]):
                    self.assertEqual(scrub_spot(once, official), once)
                    self.assertEqual({k: once[k] for k in TEXT}, {k: spot.get(k, "") for k in TEXT})

    def test_license_notes(self):
        self.assertEqual(license_note("整理自 Alan大重停車記事（Google 我的地圖）；未通過官方核驗", False), LICENSE)
        self.assertEqual(license_note("政府資料開放授權條款第 1 版；社群補充整理自 Alan大重停車記事", True), OFFICIAL_LICENSE)
        self.assertEqual(license_note("政府資料開放授權條款第 1 版；", True), OPEN_DATA)


class ToolOutputTest(unittest.TestCase):
    DESCRIPTION = ("汽車費率 20h 後牌辨析<br>有專用格4格以上，進場後順時鐘繞行，接近出口處右側可看到專用格<br>"
                   "重機獨立費率 黃牌60/DAY 紅牌100/DAY 阿嬤在入口引導<br>猴子很多東西要收好<br>不管汽車或大型重機統一費率 30h 有人看守")

    def mark(self, layer, color="7CB342", icon="1538"):
        return {"layer": layer, "name": "(30/h - 需按鈴限專用格)測試停車場", "description": self.DESCRIPTION, "icon": icon,
                "color": color, "line": False, "points": [(121.5, 25.0)]}

    def test_no_description_line_is_stored(self):
        lines = split_lines(self.DESCRIPTION.replace("<br>", "\n"))
        for layer, color in (("汽車費率", "E65100"), ("路邊友善車格", "0288D1"), ("未確定", "757575")):
            spot = normalize(self.mark(layer, color))
            stored = "\n".join(str(spot.get(k, "")) for k in (*TEXT, "fee_note")) + json.dumps(spot["parking_zones"], ensure_ascii=False)
            with self.subTest(layer=layer):
                for line in lines:
                    self.assertNotIn(line, stored)
                    for n in range(len(line) - 7):  # no 8-character run of the source either
                        self.assertNotIn(line[n:n + 8], stored)
                self.assertNotIn("來源標示為", stored)
                for key in TEXT:
                    for kept in split_lines(spot.get(key, "")):
                        self.assertTrue(allowed(key, kept, False), kept)

    def test_official_spot_states_community_facts_only(self):
        spot = normalize(self.mark("汽車費率"))
        spot.update(city="臺北市", district="中正區", address="")
        lot = {"id": "TPE1", "name": "測試停車場", "lat": 25.0, "lng": 121.5, "address": "", "fee": "", "summary": "", "motor": 0,
               "heavy": 0, "city": "臺北市", "district": "中正區", "source": "x", "url": "https://example.org"}
        official = official_spot(lot, spot, None, {}, "2026-11-01")
        self.assertEqual(official["license_note"], OFFICIAL_LICENSE)
        self.assertEqual(official["entrance_note"], f"{COMMUNITY}\n後車牌辨識")
        self.assertIn("汽車區（每小時 30 元；需按鈴或請管理員協助）", official["note"])
        self.assertEqual(official["parking_guide"], f"{COMMUNITY}\n重機專用格 4 格以上")


class CommittedDataTest(unittest.TestCase):
    def test_committed_text_is_only_facts_and_templates(self):
        for path, official in ((COMMUNITY_DATA, False), (OFFICIAL_DATA, True)):
            for spot in json.loads(path.read_text()):
                with self.subTest(spot=spot["id"]):
                    self.assertNotIn("Alan", json.dumps(spot, ensure_ascii=False))
                    if official:
                        self.assertIn(spot["license_note"], (OPEN_DATA, OFFICIAL_LICENSE))
                    else:
                        self.assertEqual(spot["license_note"], LICENSE)
                        for fee in [spot["fee_note"]] + [z["fee_note"] for z in spot.get("parking_zones", []) if "fee_note" in z]:
                            self.assertEqual(scrub_fee_text(fee), fee)
                    for key in TEXT:
                        for line in split_lines(spot.get(key, "")):
                            self.assertTrue(allowed(key, line, official), f"{key}: {line}")
                    for line in split_lines(spot.get("note", "")):
                        if official and line.startswith(COMMUNITY):
                            self.assertEqual(scrub_summary_fees(line), line)
                            claims = re.sub(r"（[^（）]*）", "", line[len(COMMUNITY):]).split("；")
                            for claim in claims:
                                self.assertTrue(is_fact(claim) or re.fullmatch(r"大型重機(可停|禁停)|停放區域：.+", claim), claim)


if __name__ == "__main__":
    unittest.main()
