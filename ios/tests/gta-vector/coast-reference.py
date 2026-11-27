#!/usr/bin/env python3
"""Build an offline geographic fixture; this does not execute the Swift codec."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import struct

HERE = Path(__file__).resolve().parent
GREEN = {
    "park", "forest", "wood", "grass", "woodland", "scrub", "heath",
    "recreation_ground", "village_green", "cemetery", "garden", "golf_course",
    "pitch", "national_park", "nature_reserve", "wetland",
}


def number(data, at):
    value = 0
    for shift in range(0, 64, 7):
        if at >= len(data):
            raise ValueError("Truncated PBF")
        byte = data[at]
        at += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, at
    raise ValueError("Overflowed varint")


def fields(data):
    at = 0
    while at < len(data):
        key, at = number(data, at)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, at = number(data, at)
        elif wire == 2:
            count, at = number(data, at)
            if count > len(data) - at:
                raise ValueError("Truncated PBF field")
            value = data[at:at + count]
            at += count
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if size > len(data) - at:
                raise ValueError("Truncated fixed PBF field")
            value = data[at:at + size]
            at += size
        else:
            raise ValueError("Unsupported PBF wire type")
        yield field, wire, value


def paths(data):
    x = y = at = 0
    current = []
    result = []
    while at < len(data):
        header, at = number(data, at)
        command, count = header & 7, header >> 3
        if not 0 < count <= 1_000_000:
            raise ValueError("Unbounded geometry")
        if command == 7:
            if count != 1 or len(current) < 3:
                raise ValueError("Invalid ring")
            current.append(current[0])
            continue
        if command not in (1, 2):
            raise ValueError("Unsupported geometry command")
        for _ in range(count):
            dx, at = number(data, at)
            dy, at = number(data, at)
            x += (dx >> 1) ^ -(dx & 1)
            y += (dy >> 1) ^ -(dy & 1)
            if command == 1:
                if current:
                    result.append(current)
                current = []
            current.append((x, y))
    if current:
        result.append(current)
    return result


def coast_features(data):
    for field, wire, layer in fields(data):
        if (field, wire) != (3, 2):
            continue
        source = list(fields(layer))
        name = next((v.decode() for f, w, v in source if (f, w) == (1, 2)), "")
        if name not in ("building", "park", "landcover", "landuse"):
            continue
        extent = next((v for f, w, v in source if (f, w) == (5, 0)), 4096)
        keys = [v.decode() for f, w, v in source if (f, w) == (3, 2)]
        values = [
            next((v.decode() for f, w, v in fields(value) if (f, w) == (1, 2)), "")
            for f, w, value in source if (f, w) == (4, 2)
        ]
        for field, wire, feature in source:
            if (field, wire) != (2, 2):
                continue
            values_in_feature = list(fields(feature))
            kind = next((v for f, w, v in values_in_feature if (f, w) == (3, 0)), 0)
            if kind != 3:
                continue
            tag_bytes = next((v for f, w, v in values_in_feature if (f, w) == (2, 2)), b"")
            tags, at = {}, 0
            while at < len(tag_bytes):
                key, at = number(tag_bytes, at)
                value, at = number(tag_bytes, at)
                tags[keys[key]] = values[value]
            if name in ("landcover", "landuse") and tags.get("class", "") not in GREEN:
                continue
            geometry = next((v for f, w, v in values_in_feature if (f, w) == (4, 2)), b"")
            yield 13 if name == "building" else 12, extent, paths(geometry)


def gcj(lat, lng):
    if lng < 72.004 or lng > 137.8347 or lat < 0.8293 or lat > 55.8271:
        return lat, lng
    x, y, pi = lng - 105, lat - 35, math.pi
    dlat = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    dlat += (20 * math.sin(6 * x * pi) + 20 * math.sin(2 * x * pi)) * 2 / 3
    dlat += (20 * math.sin(y * pi) + 40 * math.sin(y / 3 * pi)) * 2 / 3
    dlat += (160 * math.sin(y / 12 * pi) + 320 * math.sin(y * pi / 30)) * 2 / 3
    dlng = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    dlng += (20 * math.sin(6 * x * pi) + 20 * math.sin(2 * x * pi)) * 2 / 3
    dlng += (20 * math.sin(x * pi) + 40 * math.sin(x / 3 * pi)) * 2 / 3
    dlng += (150 * math.sin(x / 12 * pi) + 300 * math.sin(x / 30 * pi)) * 2 / 3
    radians = lat / 180 * pi
    magic = 1 - 0.00669342162296594323 * math.sin(radians) ** 2
    root = math.sqrt(magic)
    dlat = dlat * 180 / ((6378245 * (1 - 0.00669342162296594323)) / (magic * root) * pi)
    dlng = dlng * 180 / (6378245 / root * math.cos(radians) * pi)
    return lat + dlat, lng + dlng


def simplify(points, tolerance):
    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        if end <= start + 1:
            continue
        ax, ay = points[start]
        dx, dy = points[end][0] - ax, points[end][1] - ay
        length = dx * dx + dy * dy
        best, index = -1, -1
        for at in range(start + 1, end):
            px, py = points[at][0] - ax, points[at][1] - ay
            cross = px * dy - py * dx
            distance = px * px + py * py if length < 1e-9 else cross * cross / length
            if distance > best:
                best, index = distance, at
        if best > tolerance * tolerance:
            keep.add(index)
            stack.extend(((start, index), (index, end)))
    return [point for at, point in enumerate(points) if at in keep]


def packet_parts(data):
    count = struct.unpack_from("<H", data, 10)[0]
    at, result = 12, []
    for _ in range(count):
        cls, points = struct.unpack_from("<BH", data, at)
        end = at + 3 + points * 4
        if end > len(data):
            raise ValueError("Truncated baseline packet")
        result.append((cls, data[at:end]))
        at = end
    if at != len(data):
        raise ValueError("Trailing baseline packet bytes")
    return result


def build(raw, baseline):
    z, tile_x, tile_y = 14, 13484, 6201
    scale = 2 ** z
    center_lng = (tile_x + 0.5) / scale * 360 - 180
    center_lat = math.atan(math.sinh(math.pi * (1 - 2 * (tile_y + 0.5) / scale))) * 180 / math.pi
    ref_lat, ref_lng = gcj(center_lat, center_lng)
    factor_x = math.cos(ref_lat * math.pi / 180) * 111320
    groups, point_count = [], 0
    for cls, extent, rings in coast_features(raw):
        group = None
        for ring in rings:
            points = []
            area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(ring, ring[1:]))
            for x, y in ring:
                lng = (tile_x + x / extent) / scale * 360 - 180
                lat = math.atan(math.sinh(math.pi * (1 - 2 * (tile_y + y / extent) / scale))) * 180 / math.pi
                lat, lng = gcj(lat, lng)
                points.append(((lng - ref_lng) * factor_x, (lat - ref_lat) * 110574))
            if max(p[0] for p in points) < -2400 or min(p[0] for p in points) > 2400:
                continue
            if max(p[1] for p in points) < -2400 or min(p[1] for p in points) > 2400:
                continue
            if area >= 0:
                group = None
            points = simplify(points, 1.5 if cls == 13 else 1)
            if not 3 <= len(points) <= 1024 or point_count + len(points) > 64_000:
                if area < 0 and group is not None:
                    groups[group]["complete"] = False
                continue
            if area >= 0:
                if len(groups) >= 1024:
                    continue
                groups.append({"cls": cls, "rings": [(cls, points)], "complete": True})
                group = len(groups) - 1
            elif group is not None:
                groups[group]["rings"].append((14 if cls == 13 else 10, points))
            else:
                continue
            point_count += len(points)
    original = packet_parts(baseline)
    details, seen = [], set()
    used, parks, buildings = len(baseline), 0, 0
    groups = sorted(enumerate(groups), key=lambda pair: (
        pair[1]["cls"], math.hypot(*pair[1]["rings"][0][1][0]), pair[0]))
    for _, group in groups:
        building = group["cls"] == 13
        if not group["complete"] or (buildings >= 512 if building else parks >= 128):
            continue
        encoded = []
        for cls, points in group["rings"]:
            quantized = []
            for x, y in points:
                point = math.floor(x + 0.5), math.floor(y + 0.5)
                if not quantized or point != quantized[-1]:
                    quantized.append(point)
            if not 3 <= len(quantized) <= 1024 or any(abs(v) > 32767 for point in quantized for v in point):
                encoded = []
                break
            part = struct.pack("<BH", cls | 128, len(quantized))
            part += b"".join(struct.pack("<hh", *point) for point in quantized)
            encoded.append((cls | 128, part))
        if not encoded:
            continue
        identity = encoded[0][1]
        size = sum(len(part) for _, part in encoded)
        if identity in seen or len(original) + len(details) + len(encoded) > 7000:
            continue
        if used + size > 190_000 or used - len(baseline) + size > 48_000:
            continue
        seen.add(identity)
        details.extend(encoded)
        used += size
        buildings += int(building)
        parks += int(not building)
    ordered = [p for p in original if p[0] >= 128] + details + [p for p in original if p[0] < 128]
    data = baseline[:10] + struct.pack("<H", len(ordered)) + b"".join(part for _, part in ordered)
    assert data[12:] and len(data) == used
    assert b"".join(p for c, p in original if c < 128) == b"".join(p for c, p in ordered if c < 128)
    return data, {
        "classCounts": dict(sorted(Counter(cls for cls, _ in ordered).items())),
        "frame": 77, "cx": 0, "cy": 0, "refLat": ref_lat, "refLng": ref_lng,
        "sourceTile": {"z": z, "x": tile_x, "y": tile_y},
        "completeBaseBytesRetained": len(baseline), "optionalAreaBytes": len(data) - len(baseline),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    raw_file = HERE / "fixtures/14_13484_6201.pbf"
    base_file = HERE / "fixtures/android-gta-poi28-type1.bin"
    raw, baseline = raw_file.read_bytes(), base_file.read_bytes()
    full, metadata = build(raw, baseline)
    parts = packet_parts(full)
    retained = [(cls, part) for cls, part in parts if not 27 <= cls <= 47]
    data = full[:10] + struct.pack("<H", len(retained)) + b"".join(part for _, part in retained)
    assert all(1 <= cls <= 6 or 20 <= cls <= 26 or 138 <= cls <= 142 for cls, _ in retained)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    full_file = args.output.with_name(args.output.stem + "-full.bin")
    full_file.write_bytes(full)
    args.output.write_bytes(data)
    metadata.update({
        "kind": "Independent geographic fixture generated from raw offline PBF plus unchanged base wire bytes",
        "executesSwiftCodec": False,
        "fullPacketFile": full_file.name, "fullPacketBytes": len(full),
        "fullPacketSHA256": hashlib.sha256(full).hexdigest(),
        "classCounts": dict(sorted(Counter(cls for cls, _ in retained).items())),
        "filteredUnsupportedPOIFeatures": len(parts) - len(retained),
        "wireCompatibility": "Production theme13 legacyDisplayPacket filter: remove POI27..47 and retain coast140..142",
        "rawTileSHA256": hashlib.sha256(raw).hexdigest(),
        "basePacketSHA256": hashlib.sha256(baseline).hexdigest(),
        "packetSHA256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
    })
    args.output.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata))


if __name__ == "__main__":
    main()
