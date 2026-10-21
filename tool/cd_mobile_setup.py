"""Report which staging test builds have signing settings, as GitHub step outputs.

A platform with none of its settings is skipped with a notice; any setting present
means the owner started configuring it, so the build runs and cd_config.py reports
whatever is still missing. Values are only checked for presence, never printed.
"""
import os
import sys

SETTINGS = {
    "android": ("GOOGLE_MAPS_ANDROID_API_KEY", "ANDROID_KEYSTORE_BASE64", "ANDROID_KEY_ALIAS",
                "ANDROID_KEY_PASSWORD", "ANDROID_STORE_PASSWORD", "FIREBASE_ANDROID_APP_ID"),
    "ios": ("GOOGLE_MAPS_IOS_API_KEY", "IOS_CERTIFICATE_BASE64", "IOS_CERTIFICATE_PASSWORD",
            "IOS_PROFILE_BASE64", "FIREBASE_IOS_APP_ID"),
}


def configured(environ):
    return {platform: any(environ.get(name) for name in names) for platform, names in SETTINGS.items()}


def main(environ=os.environ, out=sys.stdout, log=sys.stderr):
    for platform, enabled in configured(environ).items():
        if not enabled:
            print(f"::notice::Staging {platform} test build skipped: none of its Environment settings are set "
                  "(see docs/CD_SETUP.md)", file=log)
        print(f"{platform}={str(enabled).lower()}", file=out)


if __name__ == "__main__":
    main()
