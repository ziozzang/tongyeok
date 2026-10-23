#!/bin/bash
# Tongyeok installer — latest GitHub release, checksum-verified, no Gatekeeper quarantine.
#   curl -fsSL https://raw.githubusercontent.com/ziozzang/tongyeok/main/install.sh | bash
# Options (env): TONGYEOK_VERSION=0.2.0  TONGYEOK_DIR=~/Applications  TONGYEOK_NO_OPEN=1
#
# Why this avoids the "Apple could not verify…" block: browsers tag downloads with com.apple.quarantine, and
# Gatekeeper refuses quarantined apps that aren't notarized (Tongyeok is ad-hoc signed). curl adds no
# quarantine flag, and we clear any leftover one, so the app opens normally.
set -euo pipefail

REPO="ziozzang/tongyeok"
PREFIX="tongyeok"
APP="Tongyeok.app"
BUNDLE_ID="net.jioh.stttrans"

say() { printf '\033[1m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) only."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || die "macOS 26 (Tahoe) or later is required (this Mac: $(sw_vers -productVersion))."

# Version: explicit, or whatever /releases/latest redirects to (no API call, no rate limit).
VERSION="${TONGYEOK_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  loc=$(curl -fsSI "https://github.com/$REPO/releases/latest" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}' | tail -1)
  VERSION="${loc##*/v}"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not determine the latest version (got '$VERSION')."

ZIP="${PREFIX}_${VERSION}_macos_arm64.zip"
BASE="https://github.com/$REPO/releases/download/v$VERSION"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading Tongyeok v$VERSION"
curl -fL --progress-bar -o "$TMP/$ZIP" "$BASE/$ZIP"
curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"

say "Verifying SHA-256"
expected=$(awk -v f="$ZIP" '$2==f || $2=="*"f {print $1}' "$TMP/SHA256SUMS")
[[ -n "$expected" ]] || die "SHA256SUMS has no entry for $ZIP."
actual=$(shasum -a 256 "$TMP/$ZIP" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || die "Checksum mismatch — download corrupted or tampered with. Nothing was installed."

ditto -x -k "$TMP/$ZIP" "$TMP/unzipped"
[[ -d "$TMP/unzipped/$APP" ]] || die "Archive does not contain $APP."

# Destination: /Applications when writable, else ~/Applications (no sudo needed).
DEST="${TONGYEOK_DIR:-}"
if [[ -z "$DEST" ]]; then
  if [[ -w /Applications ]]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
fi
mkdir -p "$DEST"

if pgrep -x Tongyeok >/dev/null; then
  say "Quitting the running Tongyeok"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x Tongyeok >/dev/null || break; sleep 0.5; done
  pgrep -x Tongyeok >/dev/null && die "Tongyeok is still running — quit it and run the installer again."
fi

say "Installing to $DEST/$APP"
rm -rf "$DEST/$APP"
ditto "$TMP/unzipped/$APP" "$DEST/$APP"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

printf '\033[32m✓ Tongyeok v%s installed: %s\033[0m\n' "$VERSION" "$DEST/$APP"
echo "  First launch asks for microphone access; system audio asks for Screen & System Audio Recording."
echo "  Updates: the app checks GitHub daily (or run this command again)."
[[ -n "${TONGYEOK_NO_OPEN:-}" ]] || open "$DEST/$APP"
