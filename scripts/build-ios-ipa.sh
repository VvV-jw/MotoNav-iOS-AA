#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${MOTONAV_DERIVED_DATA:-$ROOT/.build/DerivedData}"
OUT="$ROOT/output/ios"
mkdir -p "$OUT/logs" "$ROOT/.build"
EXPECTED="$(tr -d '[:space:]' < "$ROOT/RELEASE_VERSION")"
EXPECTED_BUILD="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"
RESULT="$OUT/logs/Build-$(date -u +%Y%m%dT%H%M%SZ).xcresult"

xcodebuild -workspace "$ROOT/ios/MotoNav.xcworkspace" -scheme MotoNav \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  build 2>&1 | tee "$OUT/logs/xcodebuild.log"

APP="$DERIVED/Build/Products/Release-iphoneos/MotoNav.app"
test -d "$APP/PlugIns/MotoNavShare.appex"
verify_version() {
  local bundle="$1" version number
  version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$bundle/Info.plist")
  number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$bundle/Info.plist")
  if [[ "$version" != "$EXPECTED" || "$number" != "$EXPECTED_BUILD" ]]; then
    printf 'Version mismatch: expected=%s(%s), bundle=%s(%s), path=%s\n' \
      "$EXPECTED" "$EXPECTED_BUILD" "$version" "$number" "$bundle" >&2
    exit 1
  fi
}
verify_version "$APP"
for extension in "$APP"/PlugIns/*.appex; do verify_version "$extension"; done

STAGE="$(mktemp -d "$ROOT/.build/Payload.XXXXXX")"
cleanup() {
  case "$STAGE" in "$ROOT/.build/"*) rm -rf "$STAGE" ;; esac
}
trap cleanup EXIT
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/MotoNav.app"
find "$STAGE/Payload" -name _CodeSignature -type d -prune -exec rm -rf {} +
find "$STAGE/Payload" -name embedded.mobileprovision -type f -delete
xcrun strip -S "$STAGE/Payload/MotoNav.app/MotoNav"
xcrun strip -S "$STAGE/Payload/MotoNav.app/PlugIns/MotoNavShare.appex/MotoNavShare"

# Isolated experiment only. Instrument before user signing, preserve SDK checks.
python3 "$ROOT/scripts/patch-countdown-tap.py" "$STAGE/Payload/MotoNav.app/MotoNav" \
  --report "$OUT/logs/countdown-observer-patch.json"

IPA="$OUT/MotoNav-aa-$EXPECTED-build$EXPECTED_BUILD-unsigned.ipa"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA" Payload)
(cd "$OUT" && shasum -a 256 "$(basename "$IPA")" > SHA256SUMS.txt)
printf 'Unsigned IPA: %s\n' "$IPA" | tee "$OUT/logs/artifact.log"
