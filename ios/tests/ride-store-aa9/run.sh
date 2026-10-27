#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/ride-store-aa9}"
mkdir -p "$BUILD/bin" "$BUILD/module-cache"
swiftc -O -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/MotoNav/RideStore.swift" "$ROOT/ios/tests/ride-store-aa9/main.swift" -o "$BUILD/bin/ride-store-aa9"
python3 - "$BUILD/bin/ride-store-aa9" "$BUILD/ride-store-ios.json" <<'PY'
import subprocess, sys
try:
    subprocess.run(sys.argv[1:], check=True, timeout=180)
except subprocess.TimeoutExpired:
    raise SystemExit("Ride store long-track/streaming/recovery regression exceeded its bounded deadline")
PY
