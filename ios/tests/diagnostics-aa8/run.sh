#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/diagnostics-aa8}"
mkdir -p "$BUILD/bin" "$BUILD/module-cache"
swiftc -O -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/MotoNav/PreparationRecovery.swift" "$ROOT/ios/MotoNav/PipelineDiagnostics.swift" \
  "$ROOT/ios/tests/diagnostics-aa8/main.swift" -o "$BUILD/bin/diagnostics-aa8"
python3 - "$BUILD/bin/diagnostics-aa8" "$ROOT/ios/tests/diagnostics-aa8/summary-fixture.json" "$BUILD/summary-ios.json" <<'PY'
import subprocess, sys
try:
    subprocess.run(sys.argv[1:], check=True, timeout=60)
except subprocess.TimeoutExpired:
    raise SystemExit("Save results and diagnostics replay exceeded its bounded deadline")
PY
