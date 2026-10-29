#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/tests/native-countdown"
xcrun clang++ -std=c++20 -fobjc-arc -fblocks -UNDEBUG \
  "$ROOT/ios/MotoNav/NativeCountdownTap.mm" "$ROOT/ios/tests/native-countdown/tap-test.mm" \
  -framework Foundation -o "$ROOT/.build/tests/native-countdown/tap-test"
"$ROOT/.build/tests/native-countdown/tap-test"
