"""Check the availability audit's parsing and classification rules (no network)."""
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from availability_audit import (
    Throttle, age_buckets, age_minutes, changes, city_get, city_lots, classify_available, coordinate_quality, credentials,
    duplicates, geometry_kind, match_staging, persistent_zero, parse_time, rows_of, safe_url, summarize_ages, tdx_offstreet_availability,
    tdx_segment_availability, type_sum_mismatch,
)


class UrlTest(unittest.TestCase):
    def test_credentials_are_removed_but_odata_kept(self):
        url = "https://x.example/api?$format=JSON&$top=5&client_secret=s3&client_id=c1&access_token=t&page=2"
        self.assertEqual(safe_url(url), "https://x.example/api?$format=JSON&$top=5&page=2")

    def test_credentials_prefer_environment_and_never_need_printing(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / ".env"
            env.write_text('TDX_CLIENT_ID="file-id"\nTDX_CLIENT_SECRET=file-secret\n')
            with patch.dict(os.environ, {"TDX_CLIENT_ID": "env-id"}, clear=False):
                os.environ.pop("TDX_CLIENT_SECRET", None)
                self.assertEqual(credentials(env), ("env-id", "file-secret"))
            with patch.dict(os.environ, {}, clear=True):
                self.assertIsNone(credentials(Path(tmp) / "missing"))


class WrapperTest(unittest.TestCase):
    def test_v1_wrapper_and_bare_list(self):
        self.assertEqual(rows_of({"UpdateTime": "x", "UpdateInterval": 60, "ParkingAvailabilities": [{"a": 1}]}), [{"a": 1}])
        self.assertEqual(rows_of([{"a": 1}]), [{"a": 1}])
        self.assertEqual(rows_of(None), [])

    def test_throttle_spaces_calls(self):
        now, slept = [0.0], []
        throttle = Throttle(13, sleep=lambda s: (slept.append(s), now.__setitem__(0, now[0] + s)), clock=lambda: now[0])
        throttle.wait()
        now[0] += 4
        throttle.wait()
        self.assertEqual(slept, [9])


class TimeTest(unittest.TestCase):
    def test_offsets_and_local_forms(self):
        fetched = "2026-10-26T07:40:00+00:00"
        self.assertEqual(age_minutes("2026-10-26T15:30:00+08:00", fetched), 10)
        self.assertEqual(age_minutes("2026-10-26 15:37:00", fetched), 3)  # city data without offset is UTC+8
        self.assertEqual(age_minutes("2026/10/26 15:39:00", fetched), 1)
        self.assertIsNone(parse_time("not a time"))
        self.assertIsNone(age_minutes(None, fetched))

    def test_buckets_keep_future_and_missing_apart(self):
        self.assertEqual(age_buckets([0.5, 5, 45, 2000, -30, None]),
                         {"0-3": 1, "3-10": 1, "30-60": 1, ">1d": 1, "future": 1, "missing": 1})
        self.assertEqual(summarize_ages([None]), {"n": 0})
        self.assertEqual(summarize_ages([1, 2, 3])["median"], 2)


class SemanticsTest(unittest.TestCase):
    def test_plan_section_2_semantics(self):
        self.assertEqual(classify_available(10, 0), "full")
        self.assertEqual(classify_available(10, 3), "free")
        self.assertEqual(classify_available(10, None), "missing")
        self.assertEqual(classify_available(10, -1), "unknown")
        self.assertEqual(classify_available(10, -9), "unknown")
        self.assertEqual(classify_available(10, -4), "invalid")
        self.assertEqual(classify_available(10, 11), "invalid")
        self.assertEqual(classify_available(None, 11), "free")

    def test_placeholder_zero_breakdown_is_flagged(self):
        new_taipei = {"AvailableSpaces": 7, "Availabilities": [{"SpaceType": 1, "AvailableSpaces": 0}, {"SpaceType": 2, "AvailableSpaces": 0}]}
        consistent = {"AvailableSpaces": 3, "Availabilities": [{"SpaceType": 2, "AvailableSpaces": 3}]}
        unknown_total = {"AvailableSpaces": -1, "Availabilities": [{"SpaceType": 2, "AvailableSpaces": 0}]}
        taipei_car_only_total = {"AvailableSpaces": 11, "Availabilities": [{"SpaceType": 1, "AvailableSpaces": 11}, {"SpaceType": 2, "AvailableSpaces": 40}]}
        genuinely_full = {"AvailableSpaces": 0, "Availabilities": [{"SpaceType": 2, "AvailableSpaces": 0}]}
        self.assertTrue(type_sum_mismatch(new_taipei))
        self.assertFalse(type_sum_mismatch(consistent))
        self.assertFalse(type_sum_mismatch(unknown_total))
        self.assertFalse(type_sum_mismatch(taipei_car_only_total))
        self.assertFalse(type_sum_mismatch(genuinely_full))

    def test_offstreet_counts_scooter_and_heavy_separately(self):
        rows = [
            {"CarParkID": "A", "AvailableSpaces": 5, "ServiceStatus": 1, "DataCollectTime": "2026-10-26T15:38:00+08:00",
             "Availabilities": [{"SpaceType": 2, "NumberOfSpaces": 10, "AvailableSpaces": 5}]},
            {"CarParkID": "B", "AvailableSpaces": 0, "ServiceStatus": 2, "DataCollectTime": "2026-10-26T15:38:00+08:00",
             "Availabilities": [{"SpaceType": 2, "NumberOfSpaces": 10, "AvailableSpaces": 0},
                                {"SpaceType": 3, "NumberOfSpaces": 2, "AvailableSpaces": -1}]},
            {"CarParkID": "C", "AvailableSpaces": 9, "ServiceStatus": 1, "Availabilities": [{"SpaceType": 1, "NumberOfSpaces": 9, "AvailableSpaces": 9}]},
        ]
        stats, snapshot = tdx_offstreet_availability(rows, "2026-10-26T07:40:00+00:00")
        self.assertEqual(stats["counts"]["has_scooter_entry"], 2)
        self.assertEqual(stats["counts"]["has_heavy_entry"], 1)
        self.assertEqual(stats["scooter_states"], {"free": 1, "full": 1})
        self.assertEqual(stats["heavy_states"], {"unknown": 1})
        self.assertEqual(stats["states_where_capacity_gt0"], {"scooter": {"free": 1, "full": 1}, "heavy": {"unknown": 1}})
        self.assertEqual(stats["service_status"], {"1": 2, "2": 1})
        self.assertEqual(stats["ages"]["n"], 2)
        self.assertEqual(set(snapshot), {"A", "B"})

    def test_segment_mismatch_is_counted(self):
        rows = [{"ParkingSegmentID": "N34", "AvailableSpaces": 7, "Availabilities": [{"SpaceType": 2, "NumberOfSpaces": 1, "AvailableSpaces": 0}]}]
        stats, _ = tdx_segment_availability(rows, "2026-10-26T07:40:00+00:00")
        self.assertEqual(stats["counts"]["scooter_entry_in_mismatch_row"], 1)
        self.assertEqual(stats["states_where_capacity_gt0"]["scooter"], {"mismatch_row": 1})


class QualityTest(unittest.TestCase):
    def test_coordinates(self):
        self.assertEqual(coordinate_quality("25.05", "121.52"), "ok")
        self.assertEqual(coordinate_quality(0, 0), "zero")
        self.assertEqual(coordinate_quality("", "121"), "missing")
        self.assertEqual(coordinate_quality("121.52", "25.05"), "outside")  # swapped
        self.assertEqual(coordinate_quality("24.43", "118.32"), "ok")  # Kinmen

    def test_duplicates_and_geometry(self):
        self.assertEqual(duplicates(["a", "a", "b", None, ""]), {"distinct": 2, "duplicated_ids": 1})
        self.assertEqual(geometry_kind("POLYGON ((121 25, ...))"), "POLYGON")
        self.assertEqual(geometry_kind(None), "missing")

    def test_round_changes(self):
        before = {"a": ("2026-10-26T15:30:00+08:00", 5, 10), "b": ("2026-10-26T15:30:00+08:00", 5, 100),
                  "c": ("2026-10-26T15:30:00+08:00", 1, 100), "gone": ("2026-10-26T15:30:00+08:00", 1, 1)}
        after = {"a": ("2026-10-26T15:20:00+08:00", 5, 10), "b": ("2026-10-26T15:30:00+08:00", 6, 100),
                 "c": ("2026-10-26T15:40:00+08:00", 90, 100), "new": ("2026-10-26T15:40:00+08:00", 1, 1)}
        self.assertEqual(changes(before, after), {"compared": 3, "time_regressed": 1, "time_unchanged": 1, "value_changed_same_time": 1,
                                                  "value_changed": 2, "time_advanced": 1, "large_jump": 1})


    def test_persistent_zero_separates_stuck_counts(self):
        r1 = {"stuck": ("t", 0, 50), "moving": ("t", 0, 50), "no_capacity": ("t", 0, 0)}
        r2 = {"stuck": ("t", 0, 50), "moving": ("t", 4, 50), "no_capacity": ("t", 0, 0)}
        self.assertEqual(persistent_zero([r1, r2]), {"rounds": 2, "with_capacity": 2, "always_zero": 1, "value_changed": 1})
        self.assertEqual(persistent_zero([r1]), {})


class CitySourceTest(unittest.TestCase):
    def test_taipei_xml_joins_static_totals_and_keeps_minus_nine(self):
        xml = ('<?xml version="1.0" encoding="UTF-8"?><DATA><UPDATETIME>Mon Oct 26 15:30:00 CST 2026</UPDATETIME>'
               '<PARK><ID>TPE0001</ID><AVAILABLECAR>11</AVAILABLECAR><AVAILABLEMOTOR>-9</AVAILABLEMOTOR>'
               '<AVAILABLEHEAVYMOTOR>2</AVAILABLEHEAVYMOTOR></PARK></DATA>').encode()
        desc = json.dumps({"data": {"UPDATETIME": "x", "park": [{"id": "TPE0001", "totalmotor": 30, "totallargemotor": "4", "type2": "民營停車場",
                                                                  "EntranceCoord": {"EntrancecoordInfo": [{"Xcod": "25.05", "Ycod": "121.52"}]}}]}}).encode()
        feed, lots = city_lots("taipei_allavailable_xml", xml, {"taipei_alldesc": desc})
        self.assertEqual(feed.isoformat(), "2026-10-26T15:30:00+08:00")
        self.assertEqual((lots[0]["scooter_total"], lots[0]["scooter_avail"], lots[0]["heavy_total"], lots[0]["heavy_avail"]), (30, -9, 4, 2))
        self.assertEqual(classify_available(lots[0]["scooter_total"], lots[0]["scooter_avail"]), "unknown")
        self.assertEqual(coordinate_quality(lots[0]["lat"], lots[0]["lon"]), "ok")

    def test_tainan_full_width_comma_and_taoyuan_swapped_names(self):
        tainan = json.dumps([{"code": "A01131", "moto": 5, "moto_total": 105, "car": 0, "update_time": "2026-10-26 15:27:30",
                              "lnglat": "22.996288，120.216051"}]).encode()
        _, lots = city_lots("tainan_parkweb", tainan, {})
        self.assertEqual((lots[0]["lat"], lots[0]["lon"], lots[0]["scooter_avail"]), ("22.996288", "120.216051", 5))
        taoyuan = ('﻿<?xml version="1.0" encoding="UTF-8"?><parkingLots updatetime="2026-10-26 15:39:03"><parkingLot>'
                   '<wgsY>121.298500</wgsY><wgsX>24.959000</wgsX><parkId>P-BD-001</parkId><totalSpace>165</totalSpace>'
                   '<surplusSpace>66</surplusSpace></parkingLot></parkingLots>').encode()
        feed, lots = city_lots("taoyuan_offstreet", taoyuan, {})
        self.assertEqual(coordinate_quality(lots[0]["lat"], lots[0]["lon"]), "ok")
        self.assertEqual((lots[0]["total"], lots[0]["avail"], lots[0]["scooter_avail"]), (165, 66, None))
        self.assertIsNotNone(feed)

    def test_paged_city_source_stops_at_empty_page(self):
        pages = {0: [{"ID": "1"}], 1: [{"ID": "2"}], 2: []}

        class Response(io.BytesIO):
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def opener(request, timeout):
            page = int(request.full_url.split("page=")[1].split("&")[0])
            return Response(json.dumps(pages[page]).encode())

        raw, status = city_get("https://x.example/json?page={page}&size=1000", opener)
        self.assertEqual((json.loads(raw), status), ([{"ID": "1"}, {"ID": "2"}], 200))


class MappingTest(unittest.TestCase):
    def test_staging_ids_join_tdx_and_city_feeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            round_dir = Path(tmp)
            (round_dir / "tdx").mkdir()
            (round_dir / "city").mkdir()
            wrapper = {"UpdateTime": "x", "ParkingAvailabilities": [
                {"CarParkID": "TPE0005", "AvailableSpaces": 3, "Availabilities": [{"SpaceType": 2, "NumberOfSpaces": 9, "AvailableSpaces": 3}]}]}
            (round_dir / "tdx" / "Taipei__OffStreet_ParkingAvailability.json").write_text(json.dumps({"meta": [], "pages": [wrapper]}))
            (round_dir / "city" / "tainan_parkweb.raw").write_text(json.dumps([{"code": "A01131", "moto": 5, "moto_total": 105, "lnglat": ""}]))
            staging = [{"city": "臺北市", "source_id": "TDX-TPE0005"}, {"city": "臺北市", "source_id": "TPE9999"},
                       {"city": "臺南市", "source_id": "A01131"}]
            result = match_staging(staging, round_dir)
        self.assertEqual(result["臺北市"], {"spots": 2, "tdx_prefixed": 1, "in_tdx_availability": 1, "tdx_usable_scooter": 1, "tdx_usable_heavy": 0})
        self.assertEqual(result["臺南市"]["city_usable_scooter"], 1)


if __name__ == "__main__":
    unittest.main()
