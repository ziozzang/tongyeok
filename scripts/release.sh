#!/bin/zsh
# Build + publish a GitHub release that the in-app updater picks up.
#   scripts/release.sh 0.2.0 ["release notes"]
# Assets: <prefix>_<version>_macos_arm64.zip (zipped .app) + SHA256SUMS  (same scheme as ziozzang/sugyeol)
# Token: $GITHUB_TOKEN, or GITHUB_TOKEN=… in ~/env. Never printed; passed to curl via a 0600 header file.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh X.Y.Z [notes]}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
PLIST=Resources/Info.plist
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
REPO=$(pb "Print :UpdateRepo"); PREFIX=$(pb "Print :UpdateAssetPrefix"); NAME=$(pb "Print :CFBundleName")
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean — commit first" >&2; exit 1; }

# Releases must be signed with the pinned certificate: an ad-hoc or other-certificate release would reset every
# user's microphone / screen-recording / Keychain permissions, and the in-app updater refuses a different cert.
SIGN_ID="${TONGYEOK_SIGN_ID:-Tongyeok Signing}"
PIN_FILE=Resources/signing-cert.sha256
leaf_sha256() {   # SHA-256 of the leaf signing certificate of an .app ("" when ad-hoc)
  local d=$(mktemp -d)
  codesign -d --extract-certificates="$d/c" "$1" 2>/dev/null || true
  [[ -f "$d/c0" ]] && shasum -a 256 "$d/c0" | awk '{print $1}'
  rm -rf "$d"
}
if [[ -n "${TONGYEOK_ALLOW_ADHOC:-}" ]]; then
  echo "⚠ TONGYEOK_ALLOW_ADHOC set: releasing without the pinned certificate check" >&2
else
  security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\"" \
    || { echo "code-signing identity '$SIGN_ID' not found (see README: Signing certificate)" >&2; exit 1; }
  [[ -s "$PIN_FILE" ]] || { echo "$PIN_FILE missing — build once, then: scripts/pin-cert.sh" >&2; exit 1; }
fi

TOKEN="${GITHUB_TOKEN:-$(grep -E '^(export )?GITHUB_TOKEN=' ~/env 2>/dev/null | head -1 | sed -E "s/^(export )?GITHUB_TOKEN=//; s/^[\"']//; s/[\"']\$//")}"
[[ -n "$TOKEN" ]] || { echo "GITHUB_TOKEN not set" >&2; exit 1; }
HDR=$(mktemp); PASS=$(mktemp); ASK=$(mktemp); chmod 600 "$HDR" "$PASS"; chmod 700 "$ASK"
trap 'rm -f "$HDR" "$PASS" "$ASK"' EXIT
printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$TOKEN" > "$HDR"
printf '%s' "$TOKEN" > "$PASS"; printf '#!/bin/sh\ncat "%s"\n' "$PASS" > "$ASK"   # git push over https without exposing the token
unset TOKEN
gitpush() { GIT_ASKPASS="$ASK" GIT_TERMINAL_PROMPT=0 git -c credential.helper= push "$@"; }

upload_assets() {   # $1 = release id; uploads zip + SHA256SUMS unless already attached
  local have=$(curl -sS -H @"$HDR" "https://api.github.com/repos/$REPO/releases/$1/assets" | python3 -c 'import json,sys; print(" ".join(a["name"] for a in json.load(sys.stdin)))')
  for f in "$ZIP" SHA256SUMS; do
    [[ " $have " == *" $f "* ]] && { echo "  $f already uploaded"; continue; }
    local type=$([[ $f == *.zip ]] && echo application/zip || echo text/plain)
    local res=$(curl -sS -H @"$HDR" -H "Content-Type: $type" --data-binary @"dist/$f" \
      "https://uploads.github.com/repos/$REPO/releases/$1/assets?name=$f")
    printf '%s' "$res" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert a.get("state")=="uploaded", a; print("  uploaded", a["name"], a["size"])' \
      || { echo "upload of $f failed: $(printf '%s' "$res" | head -c 300)" >&2; exit 1; }
  done
}
ZIP="${PREFIX}_${VERSION}_macos_arm64.zip"

# Resume: tag already released (e.g. an earlier run died during upload) → only upload what is missing.
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  EXIST=$(curl -sS -H @"$HDR" "https://api.github.com/repos/$REPO/releases/tags/v$VERSION" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' || true)
  [[ -n "$EXIST" && -f "dist/$ZIP" && -f dist/SHA256SUMS ]] || { echo "tag v$VERSION exists but no release/dist to resume" >&2; exit 1; }
  echo "▶ resuming upload for existing release v$VERSION"; upload_assets "$EXIST"; exit 0
fi

# Notes: argument, or commit subjects since the previous tag.
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
NOTES="${2:-$(git log --pretty='- %s' ${PREV:+$PREV..}HEAD | grep -v '^- Release v' || true)}"

echo "▶ $NAME v$VERSION → $REPO"
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $(( $(pb 'Print :CFBundleVersion') + 1 ))"
./build.sh release
if [[ -z "${TONGYEOK_ALLOW_ADHOC:-}" ]]; then
  GOT=$(leaf_sha256 "build/$NAME.app")
  if [[ "$GOT" != "$(tr -d ' \n' < "$PIN_FILE")" ]]; then
    git checkout -- "$PLIST"   # undo the version bump
    echo "release build is signed with ${GOT:-no certificate (ad-hoc)}, not the certificate pinned in $PIN_FILE" >&2
    exit 1
  fi
  echo "  signed with pinned certificate ${GOT:0:16}…"
fi

mkdir -p dist
rm -f "dist/$ZIP" dist/SHA256SUMS
ditto -c -k --sequesterRsrc --keepParent "build/$NAME.app" "dist/$ZIP"
(cd dist && shasum -a 256 "$ZIP" > SHA256SUMS && cat SHA256SUMS)

git add "$PLIST"
git commit -q -m "Release v$VERSION" ${COMMIT_TRAILER:+-m "$COMMIT_TRAILER"}
git tag -a "v$VERSION" -m "v$VERSION"
gitpush -q origin HEAD "v$VERSION"

BODY=$(NOTES="$NOTES" VERSION="$VERSION" NAME="$NAME" python3 -c '
import json, os
print(json.dumps({"tag_name": "v"+os.environ["VERSION"], "name": os.environ["NAME"]+" v"+os.environ["VERSION"],
                  "body": os.environ["NOTES"], "draft": False, "prerelease": False}))')
REL=$(curl -sS -H @"$HDR" -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")
# printf, not echo: zsh's echo would interpret backslash escapes inside the JSON.
ID=$(printf '%s' "$REL" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' || true)
[[ -n "$ID" ]] || { echo "release creation failed: $(printf '%s' "$REL" | head -c 500)" >&2; exit 1; }
upload_assets "$ID"
echo "✓ https://github.com/$REPO/releases/tag/v$VERSION"
