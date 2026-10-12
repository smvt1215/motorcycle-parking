"""Select an available iPhone runtime of the requested major version."""
import json
import os
import subprocess
import sys

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
version = sys.argv[1]
matches = [(runtime, device) for runtime, rows in devices.items()
           if f"iOS-{version}-" in runtime
           for device in rows if device["name"].startswith("iPhone") and device["isAvailable"]]
if not matches:
    raise SystemExit(f"No available iOS {version} runtime; this is an infrastructure failure")
runtime, device = sorted(matches, key=lambda pair: pair[0])[-1]
udid = device["udid"]
if device["state"] != "Booted":
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=180)
with open(os.environ["GITHUB_OUTPUT"], "a") as output:
    output.write(f"udid={udid}\n")
print(f"Selected {device['name']} ({runtime})")
