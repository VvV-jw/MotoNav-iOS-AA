#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/preparation-recovery}"
mkdir -p "$BUILD/bin" "$BUILD/module-cache"
swiftc -O -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/MotoNav/PreparationRecovery.swift" "$ROOT/ios/MotoNav/MapFailurePolicy.swift" \
  "$ROOT/ios/MotoNav/RawMapCache.swift" "$ROOT/ios/MotoNav/GtaServiceGate.swift" \
  "$ROOT/ios/MotoNav/MapGeo.swift" "$ROOT/ios/MotoNav/RasterProcessing.swift" \
  "$ROOT/ios/MotoNav/RouteMapPlan.swift" "$ROOT/ios/MotoNav/MapStyles.swift" \
  "$ROOT/ios/MotoNav/MapStylePolicy.swift" "$ROOT/ios/MotoNav/MvtTile.swift" \
  "$ROOT/ios/MotoNav/GtaVectorCodec.swift" "$ROOT/ios/MotoNav/GtaVectorMaps.swift" \
  "$ROOT/ios/MotoNav/RasterTransport.swift" "$ROOT/ios/MotoNav/MapReadiness.swift" \
  "$ROOT/ios/MotoNav/RouteCoverage.swift" "$ROOT/ios/MotoNav/PrefetchPolicy.swift" \
  "$ROOT/ios/MotoNav/OfflinePreparationPolicy.swift" "$ROOT/ios/MotoNav/RouteOfflineMaps.swift" \
  "$ROOT/ios/tests/offline-preparation/SDKStubs.swift" \
  "$ROOT/ios/tests/preparation-recovery/main.swift" -lz -o "$BUILD/bin/preparation-recovery"
python3 - "$BUILD/bin/preparation-recovery" <<'PY'
import subprocess, sys
try:
    subprocess.run(sys.argv[1:], check=True, timeout=90)
except subprocess.TimeoutExpired:
    raise SystemExit("Preparation recovery exceeded its bounded replay deadline")
PY
