#!/usr/bin/env python3
"""Copy and validate the three named XCTest screenshot attachments."""
import json
from pathlib import Path
import shutil
import struct
import sys

source = Path(sys.argv[1])
output = Path(__file__).resolve().parent.parent / "AppStore/screenshots/6.5-inch"
names = {"01-pattern-and-progress", "02-reading-guide-and-notes", "03-independent-pieces"}
found = {}
for test in json.loads((source / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"].split("_", 1)[0]
        if name in names:
            if attachment["isAssociatedWithFailure"]:
                raise ValueError(f"Failed capture: {name}")
            path = source / attachment["exportedFileName"]
            data = path.read_bytes()
            if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (1242, 2688):
                raise ValueError(f"Expected a 1242 × 2688 PNG: {path}")
            if data[25] not in (0, 2):
                raise ValueError(f"Screenshot must be opaque grayscale or RGB: {path}")
            found[name] = path
if set(found) != names:
    raise ValueError(f"Missing captures: {names - set(found)}")
output.mkdir(parents=True, exist_ok=True)
for name, path in sorted(found.items()):
    shutil.copyfile(path, output / f"{name}.png")
    print(output / f"{name}.png")
