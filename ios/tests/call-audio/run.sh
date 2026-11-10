#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="${MOTONAV_TEST_OUTPUT:-$ROOT/.build/call-audio}"
mkdir -p "$BUILD/bin" "$BUILD/module-cache" "$BUILD/shims" "$BUILD/tmp"
export TMPDIR="$BUILD/tmp/"

swiftc -O -module-cache-path "$BUILD/module-cache" \
  "$ROOT/ios/MotoNav/CallState.swift" \
  "$ROOT/ios/MotoNav/SpeechVolumePolicy.swift" \
  "$ROOT/ios/tests/call-audio/main.swift" \
  -o "$BUILD/bin/call-audio-policy"

# Only this executable sees the fake module. The production app imports and
# links Apple's AVFoundation through its ordinary Xcode build.
swiftc -emit-library -emit-module -module-name AVFoundation \
  -module-cache-path "$BUILD/module-cache" \
  -emit-module-path "$BUILD/shims/AVFoundation.swiftmodule" \
  "$ROOT/ios/tests/call-audio/shims/AVFoundation.swift" \
  -o "$BUILD/shims/libAVFoundation.dylib"
swiftc -O -module-cache-path "$BUILD/module-cache" \
  -I "$BUILD/shims" -L "$BUILD/shims" -lAVFoundation \
  -Xlinker -rpath -Xlinker "$BUILD/shims" \
  "$ROOT/ios/MotoNav/CallState.swift" \
  "$ROOT/ios/MotoNav/SpeechVolumePolicy.swift" \
  "$ROOT/ios/MotoNav/Speech.swift" \
  "$ROOT/ios/tests/call-audio/adapter/SDKStubs.swift" \
  "$ROOT/ios/tests/call-audio/adapter/main.swift" \
  -o "$BUILD/bin/call-audio-adapter"

python3 - "$BUILD/bin/call-audio-policy" "$BUILD/bin/call-audio-adapter" <<'PY'
import subprocess, sys
for executable in sys.argv[1:]:
    try:
        subprocess.run([executable], check=True, timeout=20)
    except subprocess.TimeoutExpired:
        raise SystemExit("Call/audio regression exceeded its bounded deadline")
PY
