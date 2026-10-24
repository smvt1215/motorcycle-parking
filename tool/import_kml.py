"""Convert authorized KML/GeoJSON points into a reviewable SQL import."""
import argparse
import json
import math
from pathlib import Path
import uuid
import xml.etree.ElementTree as ET


def points(path):
    if path.suffix.lower() in (".json", ".geojson"):
        root = json.loads(path.read_text())
        features = root.get("features", []) if root.get("type") == "FeatureCollection" else [root]
        for feature in features:
            geometry = feature.get("geometry") or {}
            if geometry.get("type") != "Point":
                raise ValueError("Only GeoJSON Point features are supported")
            lng, lat, *_ = geometry["coordinates"]
            props = feature.get("properties") or {}
            yield props.get("name", "匯入停車點"), float(lat), float(lng)
    else:
        root = ET.parse(path).getroot()
        for mark in root.findall(".//{*}Placemark"):
            coord = mark.find(".//{*}Point/{*}coordinates")
            if coord is None:
                continue
            lng, lat, *_ = (coord.text or "").strip().split(",")
            yield mark.findtext("{*}name", "匯入停車點"), float(lat), float(lng)


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    for name in ("owner", "city", "source-name", "source-url", "license-note"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--space-type", choices=["paidMotorcycle", "freeMotorcycle", "heavyOnly", "car", "offStreet",
                                                     "scooterArea", "disabledMotorcycle", "timedMotorcycle", "flexShared",
                                                     "evMotorcycle"], required=True)
    args = parser.parse_args()
    owner = str(uuid.UUID(args.owner))
    entries = list(points(args.input))
    if not entries:
        raise ValueError("Input contains no point features")
    rows = ["-- Review before execution. Authorized source only; all points remain pending.", "begin;"]
    for name, lat, lng in entries:
        if not all(map(math.isfinite, (lat, lng))) or not 20 <= lat <= 27 or not 118 <= lng <= 123:
            raise ValueError(f"Invalid Taiwan coordinate: {name}")
        if not 1 <= len(name.strip()) <= 100:
            raise ValueError("Point name must contain 1–100 characters")
        identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{args.source_url}|{name}|{lat}|{lng}"))
        values = [identifier, owner, name.strip(), args.city, args.space_type, args.source_name, args.source_url, args.license_note]
        rows.append("insert into public.community_spots(id,user_id,name,city,space_type,source_name,source_url,license_note,lat,lng,source,status) values(" + ",".join(map(literal, values)) + f",{lat},{lng},'import','pending') on conflict(id) do nothing;")
    rows.append("commit;")
    args.output.write_text("\n".join(rows) + "\n")
    print(f"Prepared {len(entries)} points in {args.output}; no database writes performed")


if __name__ == "__main__":
    main()
