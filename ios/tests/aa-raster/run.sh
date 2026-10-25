#!/bin/bash
set -euo pipefail
taskRoot="$(cd "$(dirname "$0")/../.." && pwd)"
taskOutput="${MOTONAV_TEST_OUTPUT:-$(mktemp -d)}"
mkdir -p "$taskOutput"
swiftc -O "$taskRoot/MotoNav/MapGeo.swift" "$taskRoot/MotoNav/RasterProcessing.swift" \
  "$taskRoot/MotoNav/MapStyles.swift" "$taskRoot/MotoNav/MapStylePolicy.swift" \
  "$taskRoot/MotoNav/RasterTransport.swift" "$taskRoot/MotoNav/RouteMapPlan.swift" \
  "$taskRoot/MotoNav/MvtTile.swift" "$taskRoot/MotoNav/GtaVectorCodec.swift" \
  "$taskRoot/tests/aa-raster/main.swift" -lz -o "$taskOutput/aa-raster"
MOTONAV_TEST_OUTPUT="$taskOutput" "$taskOutput/aa-raster"
