#!/usr/bin/env bash
# Native screenshots of production SwiftUI Views, using explicit simulator-only
# service adapters. No real key, device, GPS, navigation SDK or BLE is accessed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/output/ios/app-pages"
BUILD="$ROOT/.build/app-pages-preview"
DERIVED="$BUILD/DerivedData"
mkdir -p "$OUT" "$ROOT/output/ios/logs"
python3 "$ROOT/ios/previews/create-app-pages-project.py"
PROJECT="$BUILD/MotoNavPages.xcodeproj"
RUNTIME="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; assert r; print(sorted(r,key=lambda x:tuple(int(v) for v in x["version"].split(".")))[-1]["identifier"])')"
TYPE="$(xcrun simctl list devicetypes --json | python3 -c 'import json,sys; ds=[x for x in json.load(sys.stdin)["devicetypes"] if x["name"]=="iPhone 16 Pro Max"]; assert ds; print(ds[0]["identifier"])')"
DEVICE="$(xcrun simctl create MotoNav-AA10-App-Pages "$TYPE" "$RUNTIME")"
cleanup() { xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$DEVICE"
python3 - "$DEVICE" <<'PY'
import subprocess, sys
subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=240)
PY
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
python3 - "$PROJECT" "$DEVICE" "$DERIVED" <<'PY'
import subprocess, sys
subprocess.run(['xcodebuild','-quiet','-project',sys.argv[1],'-scheme','MotoNavPages','-destination','id='+sys.argv[2],'-derivedDataPath',sys.argv[3],'build-for-testing'],check=True,timeout=900)
PY
APP="$DERIVED/Build/Products/Debug-iphonesimulator/MotoNavPages.app"
xcrun simctl install "$DEVICE" "$APP"
xcrun swiftc -O "$ROOT/ios/previews/AppPagesFrameAudit.swift" -o "$BUILD/frame-audit"
SCENES=(
  page-home-top page-home-bottom
  page-display-top page-display-bottom
  page-voice page-settings-top page-settings-middle page-settings-bottom page-keys
  page-key-setup-top page-key-setup-bottom
  page-maintenance-saved page-maintenance-saving page-maintenance-failed
  page-maintenance-too-large page-maintenance-mismatch
  page-diagnostics-empty page-diagnostics-sample
  page-planner-motorcycle page-planner-bicycle page-planner-drive-top page-planner-drive-bottom
  page-navigation-independent page-navigation-drive-controls
  page-history page-place-picker page-motor-login
  page-home-large-font page-display-large-font
  page-journeys-empty page-journeys-populated page-journeys-large-font
  page-vias-editor page-vias-editor-large-font
  page-home-active-muted page-home-active-speaking
  page-navigation-drive-muted page-navigation-independent-muted
  page-navigation-drive-muted-large-font page-navigation-independent-muted-large-font
)
python3 - "$DEVICE" "$OUT" "$BUILD" "${SCENES[@]}" <<'PY'
from pathlib import Path
import hashlib, json, shutil, subprocess, sys, time
device, out, build = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,'local.motonav.app-pages-preview','data'],text=True).strip())
marker = container/'Documents'/'preview-frame-ready.json'
records = []
for scene in sys.argv[4:]:
    subprocess.run(['xcrun','simctl','launch','--terminate-running-process',device,'local.motonav.app-pages-preview',scene],check=True)
    deadline, previous, attempts, accepted = time.monotonic()+45, None, 0, None
    while time.monotonic() < deadline:
        time.sleep(0.4)
        try: ready = json.loads(marker.read_text())
        except (OSError,json.JSONDecodeError): continue
        if ready.get('scene') != scene or ready.get('displayFrames',0)<3: continue
        candidate=build/'frame-candidate.png'
        subprocess.run(['xcrun','simctl','io',device,'screenshot',str(candidate)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        audit=json.loads(subprocess.check_output([str(build/'frame-audit'),str(candidate)],text=True))
        attempts+=1
        digest=hashlib.sha256(candidate.read_bytes()).hexdigest()
        if audit['meaningfulBody'] and digest==previous:
            shutil.copyfile(candidate,out/(scene+'.png'))
            accepted={'scene':scene,'attempts':attempts,'readyMarker':ready,'frameAudit':audit,'stableConsecutiveFrames':2,'sha256':digest}
            records.append(accepted); print('Captured stable nonempty native page:',scene,flush=True); break
        previous = digest if audit['meaningfulBody'] else None
    assert accepted is not None, f'No stable, nonempty native frame for {scene}; last attempts={attempts}'
(out/'capture-readiness.json').write_text(json.dumps({'method':'Active-scene display-frame marker + CoreGraphics nonempty-body audit + two identical consecutive captures','scenes':records},ensure_ascii=False,indent=2)+'\n')
PY
python3 - "$PROJECT" "$DEVICE" "$DERIVED" "$OUT" <<'PY'
from pathlib import Path
import json, subprocess, sys
result=Path(sys.argv[4])/'AppPagesUITests.xcresult'
subprocess.run(['xcodebuild','-quiet','-project',sys.argv[1],'-scheme','MotoNavPages','-destination','id='+sys.argv[2],'-derivedDataPath',sys.argv[3],'-parallel-testing-enabled','NO','-resultBundlePath',str(result),'test-without-building'],check=True,timeout=900)
# Verify the installed Xcode's command syntax before using it. Xcode 16 emits
# JSON by default; only pass --format when its own help advertises that option.
command=['xcrun','xcresulttool','get','test-results','summary']
help_result=subprocess.run(command+['--help'],check=True,capture_output=True,text=True)
(Path(sys.argv[4])/'xcresult-summary-help.txt').write_text(help_result.stdout+help_result.stderr)
arguments=command+['--path',str(result)]
if '--format' in help_result.stdout+help_result.stderr: arguments+=['--format','json']
actual=subprocess.run(arguments,check=True,capture_output=True,text=True)
summary=json.loads(actual.stdout)
(Path(sys.argv[4])/'ui-tests-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
assert summary['totalTestCount']==14, summary
assert summary['failedTests']==0, summary
assert summary['skippedTests']==0, summary
assert summary['passedTests']==14, summary
print('PASS xcresult verified: 14 passed, 0 failed, 0 skipped.')
PY
python3 - "$OUT" "$RUNTIME" <<'PY'
from pathlib import Path
import hashlib, json, struct, sys
root=Path(sys.argv[1]); file=root/'manifest.json'; report=json.loads(file.read_text())
scenes=[]
for image in sorted(root.glob('page-*.png')):
    data=image.read_bytes(); assert data[:8]==b'\x89PNG\r\n\x1a\n'
    width,height=struct.unpack('>II',data[16:24])
    assert width>=1000 and height>width
    scenes.append({'scene':image.stem,'file':image.name,'width':width,'height':height,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'syntheticInputs':True,'sdkPlaceholder':any(x in image.stem for x in ['planner-','navigation-'])})
assert len(scenes)==40, len(scenes)
summary=json.loads((root/'ui-tests-summary.json').read_text())
assert summary['totalTestCount']==summary['passedTests']==14 and summary['failedTests']==summary['skippedTests']==0
report.update({'runtime':sys.argv[2],'device':'iPhone 16 Pro Max','scenes':scenes,'uiInteractionTests':{'suite':'AppPagesUITests','tests':summary['totalTestCount'],'passed':summary['passedTests'],'failed':summary['failedTests'],'skipped':summary['skippedTests'],'result':'AppPagesUITests.xcresult','summary':'ui-tests-summary.json','scope':'Production SwiftUI controls with explicit test service adapters'}})
readiness=json.loads((root/'capture-readiness.json').read_text())
assert len(readiness['scenes'])==40 and all(x['frameAudit']['meaningfulBody'] and x['stableConsecutiveFrames']==2 for x in readiness['scenes'])
report['captureReadiness']='capture-readiness.json'
file.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('PASS native iOS page screenshots:',len(scenes),'scenes; 14 UI interaction tests.')
PY
