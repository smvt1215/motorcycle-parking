"""Validate profile identity and distribution constraints without a Mac/keychain."""
from datetime import datetime
import unittest

from ios_signing import validate_profile


def profile(environment):
    bundle = "tw.motopark.motorcycleParking" + (".staging" if environment == "staging" else "")
    result = {"TeamIdentifier": ["TEAMABC123"], "ApplicationIdentifierPrefix": ["LEGACY1234"],
              "Entitlements": {"application-identifier": f"LEGACY1234.{bundle}", "get-task-allow": False},
              "ExpirationDate": datetime(2099, 1, 1), "Name": "Distribution Profile"}
    if environment == "staging":
        result["ProvisionedDevices"] = ["synthetic-test-device"]
    return result


class SigningProfileTest(unittest.TestCase):
    def test_legacy_app_prefix_is_independent_of_signing_team(self):
        bundle, team, _ = validate_profile(profile("staging"), "staging")
        self.assertEqual(bundle, "tw.motopark.motorcycleParking.staging")
        self.assertEqual(team, "TEAMABC123")

    def test_wrong_bundle_cannot_cross_environments(self):
        with self.assertRaisesRegex(ValueError, "bundle"):
            validate_profile(profile("production"), "staging")

    def test_production_cannot_use_an_ad_hoc_profile(self):
        data = profile("production")
        data["ProvisionedDevices"] = ["synthetic-test-device"]
        with self.assertRaisesRegex(ValueError, "Ad Hoc"):
            validate_profile(data, "production")

    def test_staging_cannot_use_an_app_store_profile(self):
        data = profile("staging")
        del data["ProvisionedDevices"]
        with self.assertRaisesRegex(ValueError, "Ad Hoc"):
            validate_profile(data, "staging")

    def test_development_and_enterprise_profiles_are_rejected(self):
        for kind in ("development", "enterprise"):
            data = profile("staging")
            if kind == "development":
                data["Entitlements"]["get-task-allow"] = True
            else:
                data["ProvisionsAllDevices"] = True
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "distribution"):
                validate_profile(data, "staging")

    def test_expired_profile_is_rejected(self):
        data = profile("staging")
        data["ExpirationDate"] = datetime(2000, 1, 1)
        with self.assertRaisesRegex(ValueError, "expired"):
            validate_profile(data, "staging")


if __name__ == "__main__":
    unittest.main()
