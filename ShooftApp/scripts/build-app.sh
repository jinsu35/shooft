#!/bin/zsh
# Builds Shooft.app (universal), signs it, and optionally notarizes it.
#
#   ./scripts/build-app.sh                 # for this Mac: signs with your "Developer ID Application" cert if
#                                          # present, else "Apple Development", else ad-hoc. A stable identity
#                                          # keeps the Accessibility permission across rebuilds.
#   RELEASE=1 ./scripts/build-app.sh       # Developer ID signed + notarized + stapled zip, ready to share.
#                                          # Uses the "Developer ID Application" cert in the keychain and the
#                                          # notarytool keychain profile "shooft" (see scripts/setup-signing.sh)
#   SANDBOX=1 ./scripts/build-app.sh       # App-Sandbox test build (separate bundle id, dist/Shooft-sandbox.app)
#
# Overrides: CODESIGN_IDENTITY="…" and NOTARY_PROFILE=name.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${SANDBOX:-}" ]]; then
  APP=dist/Shooft-sandbox.app
else
  APP=dist/Shooft.app
fi
rm -rf "$APP" && mkdir -p dist

echo "▸ building (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -v -E '^\s*$' | tail -3
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Shooft

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shooft"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

SIGN_ARGS=()
if [[ -n "${SANDBOX:-}" ]]; then
  /usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.jinsukim.shooft.sandbox' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set CFBundleName shooft-sandbox' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName shooft (sandbox)' "$APP/Contents/Info.plist"
  SIGN_ARGS+=(--entitlements Shooft.sandbox.entitlements)
  echo "▸ sandbox build: entitlements from Shooft.sandbox.entitlements"
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
# Local builds prefer the Developer ID identity too, so the app keeps the same code
# signature (and its Accessibility grant) as release builds.
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
fi
if [[ -n "${RELEASE:-}" ]]; then
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
  fi
  [[ -n "$IDENTITY" ]] || { echo "RELEASE=1 needs a 'Developer ID Application' certificate in the keychain (scripts/setup-signing.sh)"; exit 1; }
  NOTARY_PROFILE="${NOTARY_PROFILE:-shooft}"
fi
if [[ -z "$IDENTITY" ]]; then
  # Prefer the Apple Development cert of the team that also holds a distribution cert
  # (Developer ID / Apple Distribution), so the TCC grant carries over to release builds.
  local_certs=$(security find-identity -v -p codesigning 2>/dev/null)
  team_of() { security find-certificate -c "$1" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p'; }
  release_team=$(echo "$local_certs" | grep -o -E '"(Developer ID Application|Apple Distribution): [^"]*"' | head -1 | sed -E 's/.*\(([A-Z0-9]+)\)"/\1/')
  while read -r name; do
    [[ -z "$name" ]] && continue
    [[ -z "$IDENTITY" ]] && IDENTITY="$name"
    if [[ -n "$release_team" && "$(team_of "$name")" == "$release_team" ]]; then IDENTITY="$name"; break; fi
  done <<< "$(echo "$local_certs" | grep -o '"Apple Development: [^"]*"' | tr -d '"')"
fi
if [[ -n "$IDENTITY" ]]; then
  echo "▸ signing with: $IDENTITY"
  codesign --force --options runtime --timestamp "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"
else
  echo "▸ ad-hoc signing (no signing certificate found). The Accessibility permission must be granted again after every build."
  codesign --force "${SIGN_ARGS[@]}" --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | tail -2

if [[ -n "${SANDBOX:-}" ]]; then
  echo; echo "done: $APP"; exit 0
fi

ZIP=dist/shooft-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist).zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ notarizing (this takes a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▸ notarized and stapled"
fi

echo
echo "done: $APP"
echo "      $ZIP"
