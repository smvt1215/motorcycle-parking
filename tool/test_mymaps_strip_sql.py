"""The strip migrations carry only fact-only values, guarded by the md5 of what they replace (#275)."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import mymaps_strip_sql as strip
from mymaps_facts import COMMUNITY

COPIED = ["猴子很多東西要收好", "為提升路邊停車空間使用效率，台中市政府自115年起試辦", "綠川東街14號(*收費亭 不是times)",
          "勇者可以挑戰機車區"]
FEE_FRAGMENTS = ["倒退掃牌", "引導至一樓廣場停車區"]  # the fee layer's


def community(id, **fields):
    return {"id": id, "source": "import", "license_note": "整理自 Alan大重停車記事（Google 我的地圖）；未通過官方核驗",
            "note": "", "entrance_note": "", "parking_guide": "", "special_rules": "", "fee": None,
            "fee_note": "請依現場公告", "fee_source_text": "", "parking_zones": []} | fields


def official(id, **fields):
    return {"id": id, "license_note": "政府資料開放授權條款第 1 版；社群補充整理自 Alan大重停車記事（Google 我的地圖）",
            "note": "", "entrance_note": "", "parking_guide": "", "special_rules": "", "parking_zones": []} | fields


class StripSqlTest(unittest.TestCase):
    def backup(self, communities, officials, audits=()):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for name, rows in (("community_spots", communities), ("official_heavy_spots", officials), ("admin_audit_log_spots", audits)):
            (root / f"{name}.json").write_text(json.dumps([{"row": r} for r in rows], ensure_ascii=False))
        return root

    def setUp(self):
        self.rows_c = [
            community("00000000-0000-4000-8000-000000000001", note="來源標示為特殊收費或管理方式\n猴子很多東西要收好\n消費可折抵",
                      entrance_note="機車區無柵欄\n勇者可以挑戰機車區"),
            community("00000000-0000-4000-8000-000000000002", note="為提升路邊停車空間使用效率，台中市政府自115年起試辦",
                      fee_note="每小時 30 元；倒退掃牌（大型重機比照汽車費率）",
                      parking_zones=[{"id": "z1", "name": "汽車區", "access": "heavyCar", "fee_note": "每小時 30 元；倒退掃牌"}]),
            community("00000000-0000-4000-8000-000000000003", note="猴子很多東西要收好"),  # edited by an administrator
            community("00000000-0000-4000-8000-000000000004", fee={"kind": "x"}, fee_note="大型重機每小時 30 元",
                      fee_source_text="每小時 30 元；引導至一樓廣場停車區"),
        ]
        self.rows_o = [official("00000000-0000-4000-8000-000000000011",
                                note=f"{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；倒退掃牌）\n"
                                     "來源原名稱：綠川東街14號(*收費亭 不是times)\n已比對臺中市路外剩餘車位（TXG1）",
                                entrance_note=f"{COMMUNITY}\n勇者可以挑戰機車區")]
        self.audits = [{"action": "update_spot", "target_id": "00000000-0000-4000-8000-000000000003"},
                       {"action": "hide_spot", "target_id": "00000000-0000-4000-8000-000000000001"}]
        self.root = self.backup(self.rows_c, self.rows_o, self.audits)

    def test_text_migration_holds_new_values_only(self):
        sql = strip.migration(self.root, "text")
        for line in COPIED:
            self.assertNotIn(line, sql)
        self.assertIn("('00000000-0000-4000-8000-000000000001',"
                      f"'{strip.guard(*(self.rows_c[0][k] for k in strip.TEXT))}','消費可折抵停車費','無柵欄','','')", sql)
        self.assertIn(f"'{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；倒退掃牌）\n已比對臺中市路外剩餘車位（TXG1）'", sql)
        # Only update_spot counts as an administrator's edit; the edited spot is listed, not changed.
        self.assertNotIn("'00000000-0000-4000-8000-000000000003',", sql)
        self.assertIn("--   community_spots 00000000-0000-4000-8000-000000000003 note", sql)
        self.assertIn("disable trigger community_spots_flags_from_entries", sql)
        self.assertIn("enable trigger community_spots_flags_from_entries", sql)

    def test_fee_migration_builds_on_the_text_layer(self):
        sql = strip.migration(self.root, "fee")
        for line in COPIED + FEE_FRAGMENTS:
            self.assertNotIn(line, sql)
        # Fee-only updates keep the eligibility flags as they are, as the text layer does.
        for table in ("community_spots", "official_heavy_spots"):
            self.assertIn(f"disable trigger {table}_flags_from_entries", sql)
            self.assertIn(f"enable trigger {table}_flags_from_entries", sql)
        zones = [{"id": "z1", "name": "汽車區", "access": "heavyCar", "fee_note": "每小時 30 元；倒退掃牌"}]
        old = strip.guard("每小時 30 元；倒退掃牌（大型重機比照汽車費率）", "", strip.jsonb_text(zones))
        self.assertIn(f"('00000000-0000-4000-8000-000000000002','{old}','每小時 30 元；可能需倒車進場（大型重機比照汽車費率）',''", sql)
        self.assertIn('"fee_note": "每小時 30 元；可能需倒車進場"', sql)
        # Beside a structured fee only the source text changes.
        self.assertIn("'大型重機每小時 30 元','每小時 30 元'", sql)
        text = strip.text_changes(self.rows_o[0], True)["note"]
        self.assertIn(f"('00000000-0000-4000-8000-000000000011','{strip.guard(text)}',"
                      f"'{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；可能需倒車進場）\n已比對臺中市路外剩餘車位（TXG1）')", sql)

    def test_guards_match_postgres(self):
        self.assertEqual(strip.guard("a", None, "b"), hashlib.md5("a\x1f\x1fb".encode()).hexdigest())
        # jsonb sorts keys by length, then bytes, and prints ", " / ": ".
        self.assertEqual(strip.jsonb_text([{"name": "汽車區", "id": "z1", "access": "heavyCar", "fee_note": "免費"}]),
                         '[{"id": "z1", "name": "汽車區", "access": "heavyCar", "fee_note": "免費"}]')
        self.assertEqual(strip.jsonb_text({"b": None, "a": [1, True, "x\"\n"]}), '{"a": [1, true, "x\\"\\n"], "b": null}')

    def test_quotes_are_escaped(self):
        self.assertEqual(strip.literal("it's"), "'it''s'")


if __name__ == "__main__":
    unittest.main()
