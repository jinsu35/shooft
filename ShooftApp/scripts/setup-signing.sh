#!/bin/zsh
# One-time setup for release signing on this Mac.
#
#   ./scripts/setup-signing.sh <developerID_application.cer>
#
# Imports the Developer ID Application certificate (downloaded from
# developer.apple.com) together with the private key from the CSR it was
# made with (~/.steft-signing/developer-id.key), then checks that codesign
# can see the identity. Notarization credentials are stored separately:
#   xcrun notarytool store-credentials shooft --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer id>
set -euo pipefail
CER="${1:?path to developerID_application.cer}"
KEY="$HOME/.steft-signing/developer-id.key"
[[ -f "$KEY" ]] || { echo "private key not found: $KEY (the CSR was made from it)"; exit 1; }

echo "▸ importing private key"
security import "$KEY" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -T /usr/bin/security >/dev/null
echo "▸ importing certificate"
security import "$CER" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt every time.
security set-key-partition-list -S apple-tool:,apple: -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true

echo "▸ identities:"
security find-identity -v -p codesigning | grep 'Developer ID Application' || { echo "no Developer ID identity found — wrong cert or key?"; exit 1; }
echo "done. Now: RELEASE=1 ./scripts/build-app.sh"
