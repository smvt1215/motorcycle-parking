"""Only usable iPhone entries from Firebase reach Apple device registration."""
import unittest

from firebase_udids import ios_devices


class FirebaseUdidsTest(unittest.TestCase):
    def test_keeps_ios_devices_with_udid_and_name(self):
        response = {"testerUdids": [
            {"udid": "0000-A", "name": "Tester's iPhone", "platform": "ios"},
            {"udid": "0000-B", "platform": "IOS"},
            {"udid": "", "name": "blank", "platform": "ios"},
            {"udid": "0000-C", "name": "mac", "platform": "macos"},
        ]}
        self.assertEqual(ios_devices(response), [{"udid": "0000-A", "name": "Tester's iPhone"},
                                                 {"udid": "0000-B", "name": ""}])

    def test_no_testers_is_an_empty_list(self):
        self.assertEqual(ios_devices({}), [])


if __name__ == "__main__":
    unittest.main()
