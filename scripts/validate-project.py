#!/usr/bin/env python3
"""Validate packaging inputs without requiring Xcode or third-party packages."""
import json
from pathlib import Path
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
project_path = root / "MetaCine.xcodeproj/project.pbxproj"
project = project_path.read_text()
definitions = re.findall(r"^\s*([A-F0-9]{24}) = \{$", project, flags=re.MULTILINE)
assert len(definitions) == len(set(definitions)), "Duplicate Xcode object IDs"
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert references == set(definitions), f"Missing Xcode objects: {references - set(definitions)}"
for folder in ("MetaCine", "MetaCineTests"):
    for swift_file in (root / folder).rglob("*.swift"):
        assert f'path = "{swift_file.relative_to(root)}";' in project, f"Unregistered source: {swift_file}"

with (root / "MetaCine/Resources/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["NSLocalNetworkUsageDescription"]
assert info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"] is True
assert "NSAllowsLocalNetworking" not in info["NSAppTransportSecurity"], "This key overrides arbitrary IP HTTP loads"
assert info["CFBundleExecutable"] == "$(EXECUTABLE_NAME)"
assets = root / "MetaCine/Resources/Assets.xcassets"
for content_path in assets.rglob("Contents.json"):
    value = json.loads(content_path.read_text())
    assert value["info"]["version"] == 1
    for image in value.get("images", []):
        if "filename" in image:
            assert (content_path.parent / image["filename"]).is_file(), f"Missing image: {image['filename']}"

icon = (assets / "AppIcon.appiconset/AppIcon.png").read_bytes()
assert icon[:8] == b"\x89PNG\r\n\x1a\n"
assert struct.unpack(">II", icon[16:24]) == (1024, 1024)
assert icon[25] == 2, "App icon must be opaque RGB"
scheme = ET.parse(root / "MetaCine.xcodeproj/xcshareddata/xcschemes/MetaCine.xcscheme")
assert scheme.find(".//TestableReference") is not None
for ref in scheme.findall(".//BuildableReference"):
    assert ref.attrib["BlueprintIdentifier"] in references

print(f"Validated {len(definitions)} Xcode objects, all Swift sources, plist, scheme, and asset catalogs.")
