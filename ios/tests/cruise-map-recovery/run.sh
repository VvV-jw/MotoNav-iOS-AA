#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/cruise-map-recovery}"
mkdir -p "$BUILD/bin" "$BUILD/module-cache" "$BUILD/tmp"
export TMPDIR="$BUILD/tmp/"
swiftc -O -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/MotoNav/MapFeeder.swift" \
  "$ROOT/ios/MotoNav/MapFailurePolicy.swift" "$ROOT/ios/MotoNav/RawMapCache.swift" \
  "$ROOT/ios/MotoNav/GtaServiceGate.swift" "$ROOT/ios/MotoNav/MapGeo.swift" \
  "$ROOT/ios/MotoNav/RasterProcessing.swift" "$ROOT/ios/MotoNav/RouteMapPlan.swift" \
  "$ROOT/ios/MotoNav/MapStyles.swift" "$ROOT/ios/MotoNav/MapStylePolicy.swift" \
  "$ROOT/ios/MotoNav/MvtTile.swift" "$ROOT/ios/MotoNav/GtaVectorCodec.swift" \
  "$ROOT/ios/MotoNav/GtaVectorMaps.swift" "$ROOT/ios/MotoNav/RasterTransport.swift" \
  "$ROOT/ios/MotoNav/MapReadiness.swift" "$ROOT/ios/MotoNav/RouteCoverage.swift" \
  "$ROOT/ios/MotoNav/PrefetchPolicy.swift" "$ROOT/ios/MotoNav/BleBulkWriteQueue.swift" \
  "$ROOT/ios/tests/cruise-map-recovery/SDKStubs.swift" \
  "$ROOT/ios/tests/cruise-map-recovery/main.swift" -lz -o "$BUILD/bin/cruise-map-recovery"
python3 - "$BUILD/bin/cruise-map-recovery" <<'PY'
import subprocess, sys
try:
    subprocess.run(sys.argv[1:], check=True, timeout=45)
except subprocess.TimeoutExpired:
    raise SystemExit("Cruise map recovery exceeded its bounded replay deadline")
PY
