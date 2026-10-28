#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/tests/traffic-lights}"
mkdir -p "$OUT"
swiftc -O "$ROOT/ios/MotoNav/RouteGeometry.swift" \
  "$ROOT/ios/MotoNav/RouteTrafficLights.swift" \
  "$ROOT/ios/tests/traffic-lights/main.swift" -o "$OUT/test"
"$OUT/test"
