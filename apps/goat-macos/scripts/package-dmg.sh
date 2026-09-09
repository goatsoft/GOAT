#!/usr/bin/env bash
# Validate source, bundle, staged files and the read-only mounted image before delivery.
set -euo pipefail
APP="${APP:?set APP to the built GOAT.app}"
DIST="${DIST:-dist}"
CLI="${CLI:?set CLI to the built goat executable}"
CHANNEL="${RELEASE_CHANNEL:-Candidate}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/../../../scripts/distribution-notices.py" --check \
  --app-resolved "$SCRIPT_DIR/../GOAT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
ARGS=(--channel "$CHANNEL")
if [ -n "${RELEASE_TAG:-}" ]; then ARGS+=(--tag "$RELEASE_TAG"); fi
python3 "$SCRIPT_DIR/release-metadata.py" bundle "${ARGS[@]}" --app "$APP"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$SCRIPT_DIR/../release.json")"
[ -x "$CLI" ] || { echo 'error: CLI executable not found' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$CLI"
[ "$(lipo -archs "$APP/Contents/MacOS/GOAT")" = arm64 ]
[ "$(lipo -archs "$CLI")" = arm64 ]
mkdir -p "$DIST"
DMG="$DIST/GOAT-$VERSION.dmg"
# Never silently replace an already prepared candidate.
[ ! -e "$DMG" ] && [ ! -e "$DIST/release-metadata.json" ] && [ ! -e "$DIST/SHA256SUMS.txt" ] || {
  echo 'error: release outputs exist; choose a fresh DIST directory' >&2; exit 1;
}
WORK="$(mktemp -d)"
MOUNT="$WORK/mounted"
ATTACHED=0
STAGED_DMG=""
cleanup() {
  if [ "$ATTACHED" = 1 ]; then hdiutil detach "$MOUNT" >/dev/null || true; fi
  if [ -n "$STAGED_DMG" ]; then rm -f "$STAGED_DMG"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir "$WORK/stage" "$MOUNT"
ditto "$APP" "$WORK/stage/GOAT.app"
cp "$CLI" "$WORK/stage/goat"
ln -s /Applications "$WORK/stage/Applications"
LICENSE_SOURCE="$SCRIPT_DIR/../App/Resources/Licenses"
for NOTICE in LICENSE.txt LICENSE-ART.txt THIRD-PARTY-NOTICES.txt; do
  cmp "$LICENSE_SOURCE/$NOTICE" "$APP/Contents/Resources/Licenses/$NOTICE"
done
cp -R "$LICENSE_SOURCE" "$WORK/stage/Licenses"
python3 "$SCRIPT_DIR/release-metadata.py" bundle "${ARGS[@]}" --app "$WORK/stage/GOAT.app"
hdiutil create -volname "GOAT $VERSION" -srcfolder "$WORK/stage" -format UDZO "$WORK/candidate.dmg" >/dev/null
hdiutil verify "$WORK/candidate.dmg" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$WORK/candidate.dmg" >/dev/null
ATTACHED=1
python3 "$SCRIPT_DIR/release-metadata.py" bundle "${ARGS[@]}" --app "$MOUNT/GOAT.app"
codesign --verify --deep --strict "$MOUNT/GOAT.app"
codesign --verify --strict "$MOUNT/goat"
cmp "$CLI" "$MOUNT/goat"
for NOTICE in LICENSE.txt LICENSE-ART.txt THIRD-PARTY-NOTICES.txt; do
  cmp "$LICENSE_SOURCE/$NOTICE" "$MOUNT/Licenses/$NOTICE"
  cmp "$LICENSE_SOURCE/$NOTICE" "$MOUNT/GOAT.app/Contents/Resources/Licenses/$NOTICE"
done
[ "$(readlink "$MOUNT/Applications")" = /Applications ]
hdiutil detach "$MOUNT" >/dev/null
ATTACHED=0
# Prepare the manifest before publishing any local output.
cp "$WORK/candidate.dmg" "$WORK/GOAT-$VERSION.dmg"
python3 "$SCRIPT_DIR/release-metadata.py" manifest "${ARGS[@]}" --app "$APP" \
  --dmg "$WORK/GOAT-$VERSION.dmg" --cli "$CLI" --output "$WORK/release-metadata.json"
# Copy into the destination filesystem, then promote without replacing a candidate.
STAGED_DMG="$(mktemp "$DIST/.candidate.XXXXXX")"
cp "$WORK/candidate.dmg" "$STAGED_DMG"
ln "$STAGED_DMG" "$DMG"
rm "$STAGED_DMG"
cp "$WORK/release-metadata.json" "$DIST/release-metadata.json"
(cd "$DIST" && shasum -a 256 "GOAT-$VERSION.dmg" release-metadata.json > SHA256SUMS.txt)
printf '%s\n' "$DMG"
