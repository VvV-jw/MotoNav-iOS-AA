#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/quality-aa6}"
mkdir -p "$BUILD/bin" "$BUILD/module-cache"
swiftc -O -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/MotoNav/RouteCoverage.swift" "$ROOT/ios/MotoNav/PrefetchPolicy.swift" \
  "$ROOT/ios/tests/quality-aa6/main.swift" -o "$BUILD/bin/route-quality"
python3 - "$BUILD/bin/route-quality" "$ROOT/ios/tests/fixtures/route-quality-v1.json" "$BUILD/route-quality-ios.json" <<'PY'
import subprocess, sys
try:
    subprocess.run(sys.argv[1:], check=True, timeout=120)
except subprocess.TimeoutExpired:
    raise SystemExit("Route quality deadline exceeded; a core computation may be stuck.")
PY
