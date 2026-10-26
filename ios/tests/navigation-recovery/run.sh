#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/.build/tests/navigation-recovery"
mkdir -p "$out"
swiftc "$root/MotoNav/NavigationRecovery.swift" "$root/tests/navigation-recovery/main.swift" -o "$out/navigation-recovery"
"$out/navigation-recovery"
