"""Generate ignored, platform-specific Google Maps configuration without logging keys."""
import argparse
import json
from pathlib import Path
import re


def configure(config_path: Path, root: Path) -> list[str]:
    data = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) - {"android", "ios", "web"}:
        raise ValueError("設定僅接受 android、ios、web 三個欄位")
    keys = {platform: data.get(platform, "") for platform in ("android", "ios", "web")}
    for platform, key in keys.items():
        if not isinstance(key, str) or (key and not re.fullmatch(r"[A-Za-z0-9_-]+", key)):
            raise ValueError(f"{platform} 金鑰格式不正確")
    outputs = {
        root / "android/maps.properties": f"apiKey={keys['android']}\n",
        root / "ios/Flutter/Maps.xcconfig": f"GOOGLE_MAPS_API_KEY = {keys['ios']}\n",
        root / "config/maps.generated.json": json.dumps({
            "GOOGLE_MAPS_ANDROID_ENABLED": bool(keys["android"]),
            "GOOGLE_MAPS_IOS_ENABLED": bool(keys["ios"]),
            "GOOGLE_MAPS_WEB_API_KEY": keys["web"],
        }, indent=2, ensure_ascii=False) + "\n",
    }
    # Validate the entire input before replacing any existing configuration.
    for destination, content in outputs.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")
        destination.chmod(0o600)
    return [platform for platform, key in keys.items() if key]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("config/maps.local.json"))
    args = parser.parse_args()
    try:
        platforms = configure(args.config, Path(__file__).resolve().parent.parent)
    except (ValueError, OSError):
        parser.exit(1, "無法產生地圖設定，請確認設定檔存在、欄位與金鑰格式正確。\n")
    print("Google Maps 已設定平台：" + ("、".join(platforms) or "無（沿用預覽底圖）"))
    print("啟動或建置時加入 --dart-define-from-file=config/maps.generated.json")


if __name__ == "__main__":
    main()
