#!/bin/bash
# Build and package Nevumi. Public mode requires Developer ID and notary credentials.
set -euo pipefail
MODE="${1:-}"
if [[ "$MODE" != "--test" && "$MODE" != "--public" ]]; then
  echo 'Usage: package-release.sh --test|--public'
  echo 'Optional: PROJECT_DIR, OUTPUT_DIR, BUILD_DIR, RELEASE_VERSION, RELEASE_BUILD'
  echo 'Public mode also requires SIGNING_IDENTITY and NOTARY_PROFILE.'
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/.build/releases}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/DerivedData/Distribution}"
RELEASE_VERSION="${RELEASE_VERSION:-0.1.1}"
RELEASE_BUILD="${RELEASE_BUILD:-2}"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ || ! "$RELEASE_BUILD" =~ ^[0-9]+$ ]]; then
  echo 'Version and build must be numeric.' >&2; exit 2
fi
if [[ "$MODE" == "--public" ]]; then
  : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate}"
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile}"
  [[ "$SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || { echo 'Public releases require Developer ID Application signing.' >&2; exit 2; }
  security find-identity -v -p codesigning | /usr/bin/grep -F -- "$SIGNING_IDENTITY" >/dev/null || { echo 'Signing identity is not installed.' >&2; exit 2; }
fi
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
STAGING="$(mktemp -d "$BUILD_DIR/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Nevumi.app"
LOG="$BUILD_DIR/build.log"
xcodebuild -project "$PROJECT_DIR/Nevumi.xcodeproj" -scheme Nevumi \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$RELEASE_VERSION" CURRENT_PROJECT_VERSION="$RELEASE_BUILD" \
  build >"$LOG" 2>&1 || { tail -n 60 "$LOG"; exit 1; }
ditto "$BUILD_DIR/Build/Products/Release/Nevumi.app" "$APP"
# Ensure the packaged version matches the requested release.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$APP/Contents/Info.plist"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Nevumi")"
for required_arch in arm64 x86_64; do
  [[ " $ARCHITECTURES " == *" $required_arch "* ]] || { echo "Missing architecture: $required_arch" >&2; exit 1; }
done
IDENTITY='-'
SIGN_OPTIONS=(--timestamp=none)
if [[ "$MODE" == "--public" ]]; then
  IDENTITY="$SIGNING_IDENTITY"
  SIGN_OPTIONS=(--timestamp --options runtime)
fi
# Sign nested executable bundles and libraries from the inside out.
while IFS= read -r -d '' nested; do
  codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$nested"
done < <(find "$APP/Contents" -depth \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -o -type f -name '*.dylib' \) -print0)
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" \
  --entitlements "$PROJECT_DIR/Generated/Nevumi.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
notarize() {
  local upload="$1" report="$2"
  xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$report"
  /usr/bin/plutil -extract status raw "$report" | /usr/bin/grep -qx Accepted || {
    echo "Notarization did not pass. See $report; use notarytool log for the submission ID." >&2; exit 1;
  }
}
if [[ "$MODE" == "--public" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD_DIR/Nevumi-notarize.zip"
  notarize "$BUILD_DIR/Nevumi-notarize.zip" "$OUTPUT_DIR/app-notarization.json"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  DMG="$OUTPUT_DIR/Nevumi-$RELEASE_VERSION.dmg"
else
  DMG="$OUTPUT_DIR/Nevumi-$RELEASE_VERSION-TEST-NOT-NOTARIZED.dmg"
  cat > "$STAGING/READ ME - TEST BUILD.txt" <<'NOTE'
Nevumi — local test build
This build is ad-hoc signed. It has no Apple Developer ID signature or notarization.
It is not the public release. macOS may warn or block it when downloaded on another Mac.
Requirements: macOS 26 or newer. Spotify is required for music features.
Drag Nevumi into Applications. The app appears in the menu bar, not the Dock.
A signed, notarized release should replace this package before a normal public launch.
NOTE
fi
[[ ! -e "$DMG" ]] || { echo "Refusing to replace existing installer: $DMG" >&2; exit 1; }
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname 'Nevumi' -srcfolder "$STAGING" -format UDZO "$DMG"
if [[ "$MODE" == "--public" ]]; then
  codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
  notarize "$DMG" "$OUTPUT_DIR/dmg-notarization.json"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256"
echo "Installer: $DMG"
echo "Build log: $LOG"
