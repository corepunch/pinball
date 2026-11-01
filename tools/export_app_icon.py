#!/usr/bin/env python3
"""Package selected concept 10 from the original ImageGen sheet; requires Pillow."""
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SHEET = ROOT / "Art/app-icon-concepts.png"
# Concept 10: third row, second column. Inset excludes rounded tile corners,
# the presentation background, shadows and number, leaving opaque artwork.
CROP = (362, 630, 590, 858)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    with Image.open(SHEET) as sheet:
        if sheet.size != (1254, 1254):
            raise ValueError("Crop coordinates require the original 1254×1254 sheet")
        master = sheet.convert("RGB").crop(CROP).resize(
            (1024, 1024), Image.Resampling.LANCZOS
        )
    master_path = ROOT / "Art/Masters/app-icon-10.png"
    master_path.parent.mkdir(parents=True, exist_ok=True)
    master.save(master_path)

    info = {"author": "xcode", "version": 1}
    catalog = ROOT / "App/Assets.xcassets"
    iconset = catalog / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    write_json(catalog / "Contents.json", {"info": info})
    # iOS applies its own corner mask to the opaque full-bleed artwork.
    master.save(iconset / "AppIcon-1024.png")
    images = [{"filename": "AppIcon-1024.png", "idiom": "universal",
               "platform": "ios", "size": "1024x1024"}]
    write_json(iconset / "Contents.json", {"images": images, "info": info})
    print("Exported concept 10 for iPhone")


if __name__ == "__main__":
    main()
