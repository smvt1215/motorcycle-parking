"""The strip migrations carry only fact-only values, guarded by the md5 of what they replace (#275)."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import unittest.mock

import mymaps_strip_sql as strip
from mymaps_facts import COMMUNITY

COPIED = ["停車場旁有很多野狗", "為了提高路邊車位周轉率，市府自去年起試辦", "某某街1號(*收費亭 不是某品牌)",
          "膽大的人可以試試機車區"]
FEE_FRAGMENTS = ["倒車掃牌", "引導至二樓平台停車區"]  # the fee layer's


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
            community("00000000-0000-4000-8000-000000000001", note="來源標示為特殊收費或管理方式\n停車場旁有很多野狗\n消費可折抵",
                      entrance_note="機車區沒有柵欄\n膽大的人可以試試機車區"),
            community("00000000-0000-4000-8000-000000000002", note="為了提高路邊車位周轉率，市府自去年起試辦",
                      fee_note="每小時 30 元；倒車掃牌（大型重機比照汽車費率）",
                      parking_zones=[{"id": "z1", "name": "汽車區", "access": "heavyCar", "fee_note": "每小時 30 元；倒車掃牌"}]),
            community("00000000-0000-4000-8000-000000000003", note="停車場旁有很多野狗"),  # edited by an administrator
            community("00000000-0000-4000-8000-000000000004", fee={"kind": "x"}, fee_note="大型重機每小時 30 元",
                      fee_source_text="每小時 30 元；引導至二樓平台停車區"),
        ]
        self.rows_o = [official("00000000-0000-4000-8000-000000000011",
                                note=f"{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；倒車掃牌）\n"
                                     "來源原名稱：某某街1號(*收費亭 不是某品牌)\n已比對臺中市路外剩餘車位（TXG1）",
                                entrance_note=f"{COMMUNITY}\n膽大的人可以試試機車區")]
        self.audits = [{"action": "update_spot", "target_id": "00000000-0000-4000-8000-000000000003"},
                       {"action": "hide_spot", "target_id": "00000000-0000-4000-8000-000000000001"}]
        self.root = self.backup(self.rows_c, self.rows_o, self.audits)

    def test_text_migration_holds_new_values_only(self):
        sql = strip.migration(self.root, "text")
        for line in COPIED:
            self.assertNotIn(line, sql)
        self.assertIn("('00000000-0000-4000-8000-000000000001',"
                      f"'{strip.guard(*(self.rows_c[0][k] for k in strip.TEXT))}','消費可折抵停車費','無柵欄','','')", sql)
        self.assertIn(f"'{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；倒車掃牌）\n已比對臺中市路外剩餘車位（TXG1）'", sql)
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
        zones = [{"id": "z1", "name": "汽車區", "access": "heavyCar", "fee_note": "每小時 30 元；倒車掃牌"}]
        old = strip.guard("每小時 30 元；倒車掃牌（大型重機比照汽車費率）", "", strip.jsonb_text(zones))
        self.assertIn(f"('00000000-0000-4000-8000-000000000002','{old}','每小時 30 元；可能需倒車進場（大型重機比照汽車費率）',''", sql)
        self.assertIn('"fee_note": "每小時 30 元；可能需倒車進場"', sql)
        # Beside a structured fee only the source text changes.
        self.assertIn("'大型重機每小時 30 元','每小時 30 元'", sql)
        text = strip.text_changes(self.rows_o[0], True)["note"]
        self.assertIn(f"('00000000-0000-4000-8000-000000000011','{strip.guard(text)}',"
                      f"'{COMMUNITY}大型重機可停；停放區域：汽車區（每小時 30 元；可能需倒車進場）\n已比對臺中市路外剩餘車位（TXG1）')", sql)

    def test_manual_layer_renames_and_applies_admin_fixes(self):
        manual_id = next(iter(strip.MANUAL))
        admin_id = "517015fc-b75f-527b-824c-8dac7f864750"
        rows_c = self.rows_c + [community(manual_id, name="來源原名 - 猴子很多", entrance_note="機車區沒有柵欄"),
                                community(admin_id, name="松江路25巷38號", note="不用錢 沒有出入口管制 汽機車共用格2000-0600")]
        root = self.backup(rows_c, self.rows_o, self.audits + [{"action": "update_spot", "target_id": admin_id}])
        sql = strip.migration(root, "manual")
        self.assertNotIn("猴子很多", sql)
        self.assertNotIn("免付費", sql)
        name = strip.MANUAL[manual_id][0]
        # The guard is the name and text after the text layer, which already rewrote 機車區沒有柵欄.
        self.assertIn(f"('c','{manual_id}','{strip.guard('來源原名 - 猴子很多', '', '無柵欄', '', '')}',{strip.literal(name)}", sql)
        self.assertIn(f"('c','{admin_id}','{strip.guard('松江路25巷38號', '不用錢 沒有出入口管制 汽機車共用格2000-0600', '', '', '')}',"
                      "'松江路25巷38號','','無柵欄','',''", sql)
        self.assertIn("disable trigger community_spots_flags_from_entries", sql)

    def test_jilin_ban_is_a_fixed_sentence_and_its_fee_note_stays(self):
        jilin = "9b0e52fb-4c50-590b-9d8f-f100ea38178e"
        old = "一～五 06～08禁停大重機"
        rows_c = self.rows_c + [community(jilin, name="吉林路汽機車共用車格", special_rules=old,
                                          fee_note="每次 15 元（12 小時內）（大型重機比照機車費率）")]
        root = self.backup(rows_c, self.rows_o, self.audits + [{"action": "update_spot", "target_id": jilin}])
        sql = strip.migration(root, "manual")
        self.assertNotIn(old, sql)
        self.assertIn(f"('c','{jilin}','{strip.guard('吉林路汽機車共用車格', '', '', '', old)}','吉林路汽機車共用車格','','','',"
                      f"{strip.literal(strip.JILIN_BAN)}", sql)
        # Fee notes are not columns of this layer, and the fee layer skips edited spots.
        self.assertNotIn("fee_note=", sql)
        self.assertNotIn(f"'{jilin}'", strip.migration(root, "fee"))

    def test_a_spot_cannot_be_both_renamed_and_an_administrators(self):
        spot_id = next(iter(strip.MANUAL))
        with unittest.mock.patch.dict(strip.ADMIN_FIXES, {spot_id: {"note": ""}}):
            with self.assertRaises(AssertionError):
                strip.migration(self.root, "manual")

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
