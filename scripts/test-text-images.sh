#!/usr/bin/env bash
# Render real production UIFont coverage at its wire resolution, without SDK/BLE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/output/ios/text-images"
BUILD="$ROOT/.build/text-image-regression"
APP="$BUILD/MotoNavTextTests.app"
mkdir -p "$OUT" "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
python3 - "$ROOT" "$SDK" "$ARCH" "$APP" "$BUILD" <<'PY'
from pathlib import Path
import plistlib,subprocess,sys
root,sdk,arch,app,build=sys.argv[1:]
subprocess.run(['xcrun','swiftc','-Onone','-parse-as-library','-sdk',sdk,
    '-target',arch+'-apple-ios18.0-simulator','-module-cache-path',build+'/ModuleCache',
    root+'/ios/MotoNav/MapStylePolicy.swift',root+'/ios/MotoNav/TextImage.swift',
    root+'/ios/previews/TextImageRegression.swift','-o',app+'/MotoNavTextTests'],
    check=True,timeout=300)
with open(app+'/Info.plist','wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'local.motonav.text-image-regression',
        'CFBundleName':'MotoNavTextTests','CFBundleExecutable':'MotoNavTextTests',
        'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
        'CFBundleSupportedPlatforms':['iPhoneSimulator'],'MinimumOSVersion':'18.0',
        'UIDeviceFamily':[1],'UILaunchScreen':{},
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{}}},stream)
PY
codesign --force --sign - "$APP"
RUNTIME="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[v for v in json.load(sys.stdin)["runtimes"] if v.get("isAvailable") and v["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; assert r; print(sorted(r,key=lambda v:tuple(int(n) for n in v["version"].split(".")))[-1]["identifier"])')"
TYPE="$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; d=[v for v in json.load(sys.stdin)["devicetypes"] if v["name"]=="iPhone 16 Pro Max"]; assert d; print(d[0]["identifier"])')"
DEVICE="$(xcrun simctl create MotoNav-AA26-Text-Images "$TYPE" "$RUNTIME")"
cleanup() { xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$DEVICE"
python3 - "$DEVICE" <<'PY'
import subprocess,sys
subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=240)
PY
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" local.motonav.text-image-regression
python3 - "$ROOT" "$DEVICE" "$OUT" "$RUNTIME" <<'PY'
from pathlib import Path
import hashlib,json,shutil,struct,subprocess,sys,time
root,device,out,runtime=Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3]),sys.argv[4]
container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,'local.motonav.text-image-regression','data'],text=True).strip())
documents=container/'Documents';result=documents/'text-image-tests.json';deadline=time.monotonic()+45
while not result.is_file() and time.monotonic()<deadline: time.sleep(0.25)
assert result.is_file(),'Native UIKit text regression did not export its result'
report=json.loads(result.read_text())
assert report['passed'] and report['checks']>=50,report
assert len(report['fixtures'])==6
for fixture in report['fixtures']:
    raw=documents/fixture['raw'];png=documents/fixture['png'];data=raw.read_bytes()
    assert len(data)==fixture['bytes']==fixture['stride']*24 and len(data)<=3744
    assert hashlib.sha256(data).hexdigest()==fixture['sha256']
    image=png.read_bytes();assert image[:8]==b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II',image[16:24])==(fixture['width'],24)
    shutil.copy2(raw,out/raw.name);shutil.copy2(png,out/png.name)
report['sourceCommit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
report['runtime']=runtime
report['productionSourceHashes']={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in
    ['ios/MotoNav/TextImage.swift','ios/MotoNav/MapStylePolicy.swift','ios/MotoNav/BleLink.swift','ios/MotoNav/NaviBridge.swift','ios/MotoNav/WebMotor.swift']}
(out/'text-image-tests.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'checks':report['checks'],'actualUIKitFixtures':len(report['fixtures']),
    'height':24,'maximumWidth':312,'sourceCommit':report['sourceCommit']}))
PY
