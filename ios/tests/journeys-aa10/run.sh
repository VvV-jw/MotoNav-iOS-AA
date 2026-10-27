#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out="${MOTONAV_TEST_OUTPUT:-$root/.build/tests/journeys-aa10}"
mkdir -p "$out"
swiftc -O "$root/MotoNav/JourneyPolicy.swift" "$root/MotoNav/JourneyStore.swift" \
  "$root/MotoNav/RouteFlowPolicy.swift" "$root/MotoNav/NavigationRecovery.swift" \
  "$root/tests/journeys-aa10/main.swift" -o "$out/journeys-aa10"
"$out/journeys-aa10"
