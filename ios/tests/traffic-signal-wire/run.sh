#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/tests/traffic-signal-wire}"
mkdir -p "$OUT"
swiftc -O "$ROOT/ios/MotoNav/TrafficSignalWire.swift" \
  "$ROOT/ios/tests/traffic-signal-wire/main.swift" -o "$OUT/test"
"$OUT/test"
