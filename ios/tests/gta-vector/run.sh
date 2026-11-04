#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/motonav-gta-vector-$$"
mkdir -p "$BUILD"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O "$ROOT/ios/MotoNav/MapGeo.swift" "$ROOT/ios/MotoNav/MapStylePolicy.swift" \
  "$ROOT/ios/MotoNav/MapFailurePolicy.swift" "$ROOT/ios/MotoNav/RawMapCache.swift" \
  "$ROOT/ios/MotoNav/GtaServiceGate.swift" \
  "$ROOT/ios/MotoNav/MvtTile.swift" \
  "$ROOT/ios/MotoNav/GtaVectorCodec.swift" \
  "$ROOT/ios/MotoNav/GtaVectorMaps.swift" \
  "$ROOT/ios/tests/gta-vector/main.swift" -o "$BUILD/gta-vector"
PACKETS="${MOTONAV_TEST_OUTPUT:-$BUILD/packets}"
mkdir -p "$PACKETS"
MOTONAV_TEST_OUTPUT="$PACKETS" "$BUILD/gta-vector" "$ROOT/ios/tests/gta-vector/fixtures"
clang++ -std=c++17 -O2 "$ROOT/ios/tests/gta-vector/legacy-receiver.cpp" -o "$BUILD/legacy-receiver"
"$BUILD/legacy-receiver" "$PACKETS/ios-gta-type1.bin" "$PACKETS/ios-gta-aa13-type1.bin" \
  "$ROOT/ios/tests/gta-vector/fixtures/android-aa17-type1.bin"
