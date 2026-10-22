"""Write the iPhones that Firebase App Distribution testers registered, as JSON.

Uses the short-lived access token from the GitHub OIDC exchange; the output
lists {"udid", "name"} for iOS devices only, which fastlane registers with Apple.
"""
import json
import os
from pathlib import Path
import sys
from urllib.request import Request, urlopen

API = "https://firebaseappdistribution.googleapis.com/v1alpha"


def ios_devices(response):
    return [{"udid": item["udid"], "name": item.get("name", "")}
            for item in response.get("testerUdids", [])
            if item.get("udid") and item.get("platform", "ios").lower() == "ios"]


def fetch(app_id, token):
    # App IDs look like 1:<project number>:ios:<hash>. The endpoint is per project;
    # also passing mobilesdkAppId is rejected ("identifying_id is already set").
    project = app_id.split(":")[1]
    request = Request(f"{API}/projects/{project}/testers:udids",
                      headers={"Authorization": f"Bearer {token}"})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def main(argv=None):
    output = Path((argv or sys.argv)[1])
    devices = ios_devices(fetch(os.environ["FIREBASE_IOS_APP_ID"], os.environ["ACCESS_TOKEN"]))
    output.write_text(json.dumps(devices))
    print(f"Firebase testers registered {len(devices)} iPhone(s)")


if __name__ == "__main__":
    main()
