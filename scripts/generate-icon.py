#!/usr/bin/env python3
"""Render the code-native MetaCine mark as an opaque App Store icon."""
import math
from pathlib import Path
import struct
import zlib

SIZE = 1024
ROOT = Path(__file__).resolve().parent.parent


def rounded_rect(x, y, left, top, right, bottom, radius):
    dx = max(left + radius - x, 0, x - right + radius)
    dy = max(top + radius - y, 0, y - bottom + radius)
    return left <= x <= right and top <= y <= bottom and dx * dx + dy * dy <= radius * radius


rows = bytearray()
for y in range(SIZE):
    rows.append(0)
    for x in range(SIZE):
        t = (x + y) / (SIZE * 2)
        glow = max(0, 1 - math.hypot(x - 760, y - 180) / 900)
        color = [int(10 + 14 * t + 8 * glow), int(57 + 30 * t + 30 * glow), int(45 + 18 * t + 18 * glow)]
        outer = rounded_rect(x, y, 210, 220, 814, 804, 105)
        inner = rounded_rect(x, y, 268, 278, 756, 746, 55)
        if outer and not inner:
            color = [232, 243, 214]
        # A vertical film perforation and an asymmetric play aperture.
        for center_y in (335, 452, 569, 686):
            if rounded_rect(x, y, 229, center_y - 20, 251, center_y + 20, 6):
                color = [20, 78, 58]
        if 414 <= x <= 666 and abs(y - 512) <= (666 - x) * 0.66:
            color = [232, 243, 214]
        rows.extend(color)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
png += chunk(b"IEND", b"")
destination = ROOT / "MetaCine/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
destination.write_bytes(png)
print(f"Generated {destination.relative_to(ROOT)} ({len(png)} bytes)")
