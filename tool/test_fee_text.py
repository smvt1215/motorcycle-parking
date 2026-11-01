import json
import random
import unittest

import fee_text
import gen_contract_sql as gen


class FeeTextTest(unittest.TestCase):
    """tool/fee_text.py writes the shared sentences, so its bound is the
    bound of what SQL, Dart and Deno write."""

    @classmethod
    def setUpClass(cls):
        cls.cases = json.loads(gen.CASES.read_text())
        cls.fee = json.loads(gen.CONTRACT.read_text())["fee"]

    def test_the_shared_sentences(self):
        self.assertTrue(self.cases["fee_notes"])
        for case in self.cases["fee_notes"]:
            with self.subTest(case=case["name"]):
                self.assertEqual(fee_text.fee_note_of(case["fee"]), case["note"])

    def test_money_keeps_two_decimals_at_most(self):
        self.assertEqual(fee_text.money(15, 150), "22.5")
        self.assertEqual(fee_text.money(33, 125), "41.25")
        self.assertEqual(fee_text.money(20.0), "20")

    def test_no_random_fee_runs_past_the_bound(self):
        """Random fees within the contract never write a longer sentence."""
        bound = fee_text.fee_note_max_length(self.fee)
        rng = random.Random(20261026)
        days = ["all", "weekday", "holiday"]

        def amount():
            return rng.choice([0, 1, 99, 9999, 10000])

        def minutes():
            return rng.choice([1, 30, 59, 60, 1439, 1440])

        def nested():
            mode = rng.choice(["free", "hourly", "per_visit"])
            r = {"mode": mode}
            if mode == "hourly":
                r.update(amount=amount(), per_minutes=minutes())
                if rng.random() < 0.5:
                    r["daily_cap"] = amount()
                    if rng.random() < 0.7:
                        r["cap_reset"] = rng.choice(list(fee_text.RESET))
            elif mode == "per_visit":
                r["amount"] = amount()
                if rng.random() < 0.7:
                    r["renew"] = rng.choice(["none", "midnight"])
                if rng.random() < 0.5:
                    r["extension_amount"] = amount()
            return r

        def rate():
            if rng.random() < 0.1:
                return {"mode": "not_applicable"}
            if rng.random() < 0.5:
                return nested()
            periods = []
            for _ in range(rng.randint(1, 6)):
                p = {"days": rng.choice(days + [rng.sample(fee_text.WEEKDAYS, rng.randint(1, 7))]),
                     "rate": nested()}
                if rng.random() < 0.7:
                    p["from"], p["to"] = rng.sample(["00:00", "08:00", "20:00", "23:59"], 2)
                periods.append(p)
            r = {"mode": "by_time", "periods": periods}
            if rng.random() < 0.5:
                r["cross_period"] = rng.choice(["each_period", "entry_only"])
            return r

        for _ in range(3000):
            fee = {k: rate() for k in ("scooter", "heavy", "car") if rng.random() < 0.8}
            if "heavy" in fee and rng.random() < 0.3:
                fee["heavy"] = {"mode": rng.choice(["same_as_scooter", "same_as_car"])}
            self.assertLessEqual(len(fee_text.fee_note_of(fee)), bound, json.dumps(fee, ensure_ascii=False))


if __name__ == "__main__":
    unittest.main()
