#!/usr/bin/env bash
# Notarize + staple a DMG with Apple's notary service. Runs only when the required
# credentials are present. Official releases must never skip this step.
#
# Env:
#   DMG                 path to the .dmg to notarize
#   NOTARY_APPLE_ID     Apple ID email
#   NOTARY_PASSWORD     app-specific password (appleid.apple.com → App-Specific Passwords)
#   APPLE_TEAM_ID       10-char team id
set -euo pipefail

DMG="${DMG:?set DMG to the .dmg path}"

if [ -z "${NOTARY_APPLE_ID:-}${NOTARY_PASSWORD:-}${APPLE_TEAM_ID:-}" ]; then
  if [ "${RELEASE_CHANNEL:-Development}" = Release ]; then
    echo "notarize: official releases require notarization credentials" >&2
    exit 1
  fi
  echo "notarize: credentials not set; skipped. Gatekeeper acceptance remains unverified."
  exit 0
fi
if [ -z "${NOTARY_APPLE_ID:-}" ] || [ -z "${NOTARY_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "notarize: incomplete credentials; refusing to silently skip" >&2
  exit 1
fi

RESULT="$(mktemp)"
trap 'rm -f "$RESULT"' EXIT

echo "notarize: submitting $DMG …"
xcrun notarytool submit "$DMG" \
  --apple-id "$NOTARY_APPLE_ID" \
  --password "$NOTARY_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait --output-format json > "$RESULT"
python3 -c 'import json,sys; result=json.load(open(sys.argv[1])); sys.exit(0 if result.get("status") == "Accepted" else "notarize: submission was not Accepted")' "$RESULT"

echo "notarize: stapling ticket …"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "notarize: done."
