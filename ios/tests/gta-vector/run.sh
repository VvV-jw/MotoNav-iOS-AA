#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${TMPDIR:-/tmp}/motonav-gta-vector-$$"
mkdir -p "$BUILD"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O "$ROOT/ios/MotoNav/MapGeo.swift" \
  "$ROOT/ios/MotoNav/MapFailurePolicy.swift" "$ROOT/ios/MotoNav/RawMapCache.swift" \
  "$ROOT/ios/MotoNav/GtaServiceGate.swift" \
  "$ROOT/ios/MotoNav/MvtTile.swift" \
  "$ROOT/ios/MotoNav/GtaVectorCodec.swift" \
  "$ROOT/ios/MotoNav/GtaVectorMaps.swift" \
  "$ROOT/ios/tests/gta-vector/main.swift" -o "$BUILD/gta-vector"
"$BUILD/gta-vector" "$ROOT/ios/tests/gta-vector/fixtures"
