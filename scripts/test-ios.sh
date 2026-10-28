#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_OUTPUT="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/tests}"
mkdir -p "$TEST_OUTPUT/bin" "$TEST_OUTPUT/module-cache" "$TEST_OUTPUT/tmp"
export TMPDIR="$TEST_OUTPUT/tmp/"
export CLANG_MODULE_CACHE_PATH="$TEST_OUTPUT/module-cache"
cd "$ROOT"

run_swift() {
  local name="$1" optimization="$2"
  shift 2
  printf '\nRunning %s\n' "$name"
  swiftc "$optimization" -module-cache-path "$TEST_OUTPUT/module-cache" \
    "$@" -o "$TEST_OUTPUT/bin/$name"
  "$TEST_OUTPUT/bin/$name"
}

MAP_SOURCES=(
  ios/MotoNav/MapFailurePolicy.swift ios/MotoNav/RawMapCache.swift ios/MotoNav/GtaServiceGate.swift
  ios/MotoNav/MapGeo.swift ios/MotoNav/RasterProcessing.swift
  ios/MotoNav/RouteMapPlan.swift ios/MotoNav/MapStyles.swift
  ios/MotoNav/MapStylePolicy.swift ios/MotoNav/MvtTile.swift
  ios/MotoNav/GtaVectorCodec.swift ios/MotoNav/GtaVectorMaps.swift
  ios/MotoNav/RasterTransport.swift
)

run_swift arrival -O ios/MotoNav/ArrivalPolicy.swift ios/tests/arrival/main.swift
run_swift location-readiness -O ios/MotoNav/LocationReadiness.swift ios/tests/location-readiness/main.swift
run_swift map-readiness -O ios/MotoNav/MapReadiness.swift ios/tests/map-readiness/main.swift
run_swift navigation-recovery -O ios/MotoNav/NavigationRecovery.swift ios/tests/navigation-recovery/main.swift
run_swift recalculation-notice -O ios/MotoNav/IndependentRecalculationNotice.swift ios/tests/recalculation-notice/main.swift
run_swift pipeline-diagnostics -O ios/MotoNav/PipelineDiagnostics.swift ios/tests/pipeline-diagnostics/main.swift
run_swift search-policy -O ios/MotoNav/SearchRequestPolicy.swift ios/tests/search-policy/main.swift
run_swift route-flow -O ios/MotoNav/RouteFlowPolicy.swift ios/MotoNav/NavigationRecovery.swift ios/tests/route-flow/main.swift
run_swift offline-policy -O ios/MotoNav/OfflinePreparationPolicy.swift ios/tests/offline-policy/main.swift
run_swift map-failure-policy -O ios/MotoNav/MapFailurePolicy.swift ios/tests/map-failure-policy/main.swift
run_swift gta-service-gate -O ios/MotoNav/MapFailurePolicy.swift ios/MotoNav/GtaServiceGate.swift ios/tests/gta-service-gate/main.swift
run_swift raw-cache -O ios/MotoNav/MapFailurePolicy.swift ios/MotoNav/RawMapCache.swift ios/tests/raw-cache/main.swift
run_swift map-cache -Onone "${MAP_SOURCES[@]}" ios/tests/map-cache/main.swift -lz
run_swift offline-preparation -O "${MAP_SOURCES[@]}" ios/MotoNav/MapReadiness.swift \
  ios/MotoNav/RouteCoverage.swift ios/MotoNav/PrefetchPolicy.swift \
  ios/MotoNav/OfflinePreparationPolicy.swift ios/MotoNav/RouteOfflineMaps.swift ios/tests/offline-preparation/SDKStubs.swift \
  ios/tests/offline-preparation/main.swift -lz
run_swift arrival-relay -O ios/MotoNav/ArrivalPolicy.swift \
  ios/MotoNav/NaviSessionCallbacks.swift ios/MotoNav/LaneGuidance.swift ios/tests/arrival-relay/SDKStubs.swift \
  ios/tests/arrival-relay/main.swift
# This legacy suite uses assert(), which must remain enabled.
run_swift cruise-idle -Onone ios/MotoNav/CruiseIdleTimer.swift ios/tests/main.swift
run_swift ble-bulk -O ios/MotoNav/BleBulkWriteQueue.swift \
  ios/MotoNav/BleWritePacer.swift ios/tests/ble-bulk/main.swift
run_swift ble-pacing -O ios/MotoNav/BleWritePacer.swift ios/tests/ble-pacing/main.swift
run_swift ble-capability -O ios/MotoNav/BleCapabilityProbe.swift ios/tests/ble-capability/main.swift
run_swift music -O ios/MotoNav/AMSMetadata.swift ios/tests/music/main.swift
run_swift lyrics -O ios/MotoNav/LyricsTimeline.swift ios/tests/lyrics/main.swift
run_swift lyrics-sync -O ios/MotoNav/LyricsDisplaySync.swift ios/tests/lyrics-sync/main.swift
run_swift weather -O ios/MotoNav/QWeatherForecast.swift ios/tests/weather/main.swift
run_swift map-defaults -O ios/MotoNav/MapDefaults.swift ios/tests/map-defaults/main.swift
run_swift maps -O "${MAP_SOURCES[@]}" ios/tests/maps/main.swift -lz
run_swift four-styles -O "${MAP_SOURCES[@]}" ios/tests/four-styles/main.swift -lz
run_swift amap-only -O "${MAP_SOURCES[@]}" ios/MotoNav/SatelliteRaster.swift \
  ios/MotoNav/MapDefaults.swift ios/tests/amap-only/main.swift -lz
# Runs the production URL/parser/tracker code plus parity-015/main.swift.
python3 ios/tests/webmotor/check.py
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/traffic-lights" bash ios/tests/traffic-lights/run.sh

MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/gta-vector" bash ios/tests/gta-vector/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/aa-raster" bash ios/tests/aa-raster/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/quality-aa6" bash ios/tests/quality-aa6/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/preparation-recovery" bash ios/tests/preparation-recovery/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/preparation-stress" bash ios/tests/preparation-stress/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/diagnostics-aa8" bash ios/tests/diagnostics-aa8/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/ride-store-aa9" bash ios/tests/ride-store-aa9/run.sh
MOTONAV_TEST_OUTPUT="$TEST_OUTPUT/journeys-aa10" bash ios/tests/journeys-aa10/run.sh
printf '\nAll iOS regression suites passed.\n'
