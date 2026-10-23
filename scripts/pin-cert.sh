#!/bin/zsh
# Pin the signing certificate of build/Tongyeok.app: writes its SHA-256 to Resources/signing-cert.sha256.
# release.sh refuses to publish a build signed with anything else. The fingerprint is public; the key is not.
#   ./build.sh && scripts/pin-cert.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Resources/Info.plist).app"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
codesign -d --extract-certificates="$d/c" "$APP" 2>/dev/null || true
[[ -f "$d/c0" ]] || { echo "$APP is ad-hoc signed — create the 'Tongyeok Signing' certificate first (README)" >&2; exit 1; }
shasum -a 256 "$d/c0" | awk '{print $1}' > Resources/signing-cert.sha256
echo "pinned $(cat Resources/signing-cert.sha256)  ($(openssl x509 -inform der -in "$d/c0" -noout -subject -enddate | tr '\n' ' '))"
echo "commit it: git add Resources/signing-cert.sha256"
