#!/usr/bin/env bash
# A disposable simulator host renders the exact production coverage component.
# It does not load the navigation SDK, use real coordinates, or touch a physical device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/output/ios/previews"
BUILD="$ROOT/.build/preparation-preview"
mkdir -p "$OUT" "$BUILD/MotoNavPreview.app"
APP="$BUILD/MotoNavPreview.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
xcrun swiftc -O -parse-as-library -sdk "$SDK" -target "$ARCH-apple-ios18.0-simulator" \
  "$ROOT/ios/MotoNav/RouteCoverage.swift" \
  "$ROOT/ios/MotoNav/RouteCoverageSummaryView.swift" \
  "$ROOT/ios/previews/PreparationPreview.swift" -o "$APP/MotoNavPreview"
python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'local.motonav.preparation-preview',
        'CFBundleName':'MotoNavPreview', 'CFBundleExecutable':'MotoNavPreview',
        'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0',
        'CFBundleSupportedPlatforms':['iPhoneSimulator'], 'MinimumOSVersion':'18.0',
        'UIDeviceFamily':[1], 'UILaunchScreen':{}, 'UIUserInterfaceStyle':'Dark',
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{}}}, f)
PY
codesign --force --sign - "$APP"
RUNTIME="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; assert r, "No available iOS simulator runtime"; print(sorted(r,key=lambda x:tuple(int(v) for v in x["version"].split(".")))[-1]["identifier"])')"
TYPE="$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; ds=[x for x in json.load(sys.stdin)["devicetypes"] if x["name"]=="iPhone 16 Pro Max"]; assert ds; print(ds[0]["identifier"])')"
DEVICE="$(xcrun simctl create MotoNav-AA6-Preparation-Preview "$TYPE" "$RUNTIME")"
cleanup() { xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$DEVICE"
python3 - "$DEVICE" <<'PY'
import subprocess, sys
subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=240)
PY
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE" "$APP"
for SCENE in overview gap ready; do
  xcrun simctl launch --terminate-running-process "$DEVICE" local.motonav.preparation-preview "$SCENE"
  sleep 2
  xcrun simctl io "$DEVICE" screenshot "$OUT/coverage-$SCENE.png"
done
printf 'PASS native simulator component previews; production coverage view, synthetic inputs, no navigation SDK or physical device.\n'
