#!/bin/bash
# Developer ID signing + notarization for a distributable pp DMG.
#
#   scripts/sign-and-notarize.sh [path/to/pp.app]
#
# Requires (one-time):
#   - an Apple Developer Program membership
#   - a "Developer ID Application" certificate in your login keychain
#   - notarytool credentials stored once, e.g.
#       xcrun notarytool store-credentials pp-notary \
#         --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
#
# build.sh signs locally so you can run pp during development. This script produces the
# build you give to other people: hardened runtime, Developer ID, notarized, stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-$PWD/.build/app/pp.app}"
DMG="${DMG_PATH:-$PWD/.build/pp.dmg}"
ENTITLEMENTS="Resources/pp.entitlements"
BUNDLE_ID="local.pp"
PROFILE="${NOTARY_PROFILE:-pp-notary}"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found. Run ./build.sh first." >&2
  exit 1
fi

IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<'EOF'
error: no "Developer ID Application" certificate found.

This step cannot be faked: an unsigned or self-signed build is rejected by Gatekeeper on
every other Mac. To proceed you need an Apple Developer Program membership and a
Developer ID Application certificate in your keychain:

  1. Join the Apple Developer Program (99 USD/year).
  2. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application.
  3. Re-run this script.

Local development does not need this: ./build.sh signs with a local identity and pp runs
on this Mac.
EOF
  exit 2
fi

echo "Signing with: $IDENTITY"
codesign --force --deep --options runtime --timestamp \
  --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

# Assert Apple Events automation entitlement is present
echo "Checking entitlements for com.apple.security.automation.apple-events…"
ENTITLEMENT_DUMP="$(codesign -d --entitlements :- "$APP" 2>&1)"
if ! echo "$ENTITLEMENT_DUMP" | grep -q "com.apple.security.automation.apple-events"; then
  echo "error: missing required com.apple.security.automation.apple-events entitlement!" >&2
  exit 1
fi

# The DMG is what gets shipped, so it is signed too.
if [[ -f "$DMG" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

echo "Submitting for notarization (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "Stapling the notarization ticket…"
xcrun stapler staple "$DMG"
if ! xcrun stapler validate "$DMG"; then
  echo "error: the notarization ticket did not validate." >&2
  exit 1
fi

echo
echo "Gatekeeper assessment:"
spctl -a -vvv --type install "$DMG" || true

cat <<EOF

Notarized DMG ready: $DMG
Verify on a clean Mac with:
  spctl -a -vvv --type install "$DMG"
  xcrun stapler validate "$DMG"
EOF
