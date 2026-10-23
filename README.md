# Tongyeok (통역)

Live speech recognition + translation for macOS — native, on-device speech recognition with Apple's
**SpeechAnalyzer / SpeechTranscriber**, translated by an LLM (OpenAI-compatible, e.g. Gemma), Apple Translation or Google.

마이크/시스템 소리를 실시간으로 받아쓰고 번역하는 맥 앱.

- Microphone or system audio (ScreenCaptureKit); energy VAD so silence never reaches the recognizer
- Original / translation side-by-side, row-aligned; timestamps; copy (with timestamps) and Markdown export
- Sentence-aware: fragments split by pauses are merged before translation (and retroactively fixed)
- Two-way language auto-detect (e.g. EN⇄KO), ⇄ swap, pause / push-to-talk (Space)
- LLM prompt carries user context + previous sentences for consistent terminology
- Low-quality recording (AAC 32 kbps or AIFF, 16 kHz mono)
- Floating subtitle window (⌘T): original | translation side by side, resizable, click-through, full screen (⌘⇧F / double-click)
- Speech recognition: Apple on-device, or Whisper via any OpenAI-compatible `/audio/transcriptions` (LiteLLM etc.)
- Meeting minutes on stop (⇧⌘M anytime): summary, decisions, action items by speaker → Markdown + Mail draft
- Experimental speaker labels by voice (CAM++ CoreML embedding, ~17 MB, downloaded on first use)
- API keys in the Keychain (one item; ad-hoc signed updates ask for access once); transcript autosaved and offered back after a crash
- LiteLLM endpoint/key auto-filled from `~/env` (`LITELLM_OPENAI_BASE_URL`, `LITELLM_OPENAI_API_KEY`)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ziozzang/tongyeok/main/install.sh | bash
```

Downloads the latest release, checks it against `SHA256SUMS`, installs to `/Applications` (or `~/Applications` if
that isn't writable) and opens it. Run the same line again to update. Options: `TONGYEOK_VERSION=0.2.0`,
`TONGYEOK_DIR=~/Applications`, `TONGYEOK_NO_OPEN=1` (put them before `bash`, e.g. `… | TONGYEOK_NO_OPEN=1 bash`).

Requirements: macOS 26 (Tahoe) or later, Apple Silicon.

<details><summary>Manual install</summary>

1. Download `tongyeok_<version>_macos_arm64.zip` from [Releases](https://github.com/ziozzang/tongyeok/releases/latest).
2. Unzip and move **Tongyeok.app** to `/Applications`.
3. Clear the download flag (see below): `xattr -dr com.apple.quarantine /Applications/Tongyeok.app`
</details>

### "Tongyeok can't be opened" / "Apple could not verify…"

Tongyeok is ad-hoc signed, not notarized by Apple. A browser-downloaded app carries a *quarantine* flag, and
Gatekeeper refuses to open quarantined apps that aren't notarized. On macOS 15+ the old right-click → Open trick
no longer works. Fix it either way:

- install with the one-liner above (curl sets no quarantine flag), or
- `xattr -dr com.apple.quarantine /Applications/Tongyeok.app`, or
- System Settings → Privacy & Security → scroll down → **Open Anyway** (after one blocked launch attempt).

The in-app updater clears the flag on updates itself.

### Permission prompts after an update

macOS ties privacy permissions to the app's code signature. Releases signed with the project's fixed certificate
keep them across updates; an ad-hoc signed build (or the first update from an ad-hoc version) asks again for:

- **Microphone**, and **Screen & System Audio Recording** (system audio input) — allow, then restart the app if
  system audio stays silent (System Settings → Privacy & Security → Screen & System Audio Recording);
- **Keychain** access to the saved API keys ("Tongyeok wants to use … net.jioh.stttrans") — choose
  *Always Allow*. All keys are in one Keychain item, so it's a single prompt.

Uninstall: `rm -rf /Applications/Tongyeok.app ~/Library/Application\ Support/Tongyeok` and
`defaults delete net.jioh.stttrans`; the API keys are under `net.jioh.stttrans` in Keychain Access.

## Updates

The app checks GitHub Releases once a day (and via **Check for Updates…**). Updates are verified against the
release's `SHA256SUMS`, installed in place and the app relaunches. Set `NO_UPDATE_CHECK=1` to disable.
Command line: `Tongyeok.app/Contents/MacOS/Tongyeok --update [--check]`.

## Build & release

### Signing certificate (maintainers)

Builds are signed with a self-signed **code-signing** certificate named `Tongyeok Signing` (override with
`TONGYEOK_SIGN_ID`). Its designated requirement (bundle id + certificate) stays the same across builds, so users'
microphone / screen-recording / Keychain permissions survive updates, and the in-app updater refuses an update
signed by anything else. Without the certificate `build.sh` falls back to ad-hoc signing (with a warning) and
`release.sh` refuses to publish.

1. Keychain Access → Certificate Assistant → Create a Certificate… — Name `Tongyeok Signing`, Identity Type
   *Self-Signed Root*, Certificate Type *Code Signing*, **Let me override defaults** → validity 7300 days.
2. Double-click it → Trust → Code Signing: *Always Trust*.
3. Export it as a password-protected `.p12` and keep it somewhere safe. Never commit it: whoever has the key can
   sign apps that inherit Tongyeok's permissions and Keychain access. A new certificate resets everyone's
   permissions once (and needs a release that the old updater accepts — see `SigningCheck`).
4. `./build.sh && scripts/pin-cert.sh`, then commit `Resources/signing-cert.sha256` (the public fingerprint
   `release.sh` checks every release build against).


```sh
./build.sh                         # → build/Tongyeok.app  (plain swiftc, no Xcode project)
scripts/release.sh 0.2.0 "notes"   # bump version, build, zip + SHA256SUMS, tag, push, GitHub release
```
Release assets follow the same scheme as [sugyeol](https://github.com/ziozzang/sugyeol):
`tongyeok_<version>_macos_arm64.zip` + `SHA256SUMS`.
## Tests

```sh
xcrun swiftc -target arm64-apple-macosx26.0 -o build/unit Tests/unit/main.swift Sources/Shared/{SentenceAssembler,Common,Translator}.swift && build/unit
xcrun swiftc -O -target arm64-apple-macosx26.0 -o build/cli Tests/cli/main.swift \
  Sources/App/{SpeechEngine,AudioSource}.swift Sources/Shared/{Common,Translator,SentenceAssembler,VAD}.swift
say -o /tmp/t.aiff "Hello everyone. [[slnc 1500]] Let's begin." && STTTRANS_DEBUG=1 build/cli /tmp/t.aiff en-US google ko
```
Speaker clustering check (labeled 16 kHz mono WAVs):
```sh
xcrun swiftc -O -target arm64-apple-macosx26.0 -o build/speakers Tests/speakers/main.swift \
  Sources/Shared/{Speakers,Common,Translator}.swift && build/speakers Alice=a1.wav Bob=b1.wav Alice=a2.wav
```
Debug hooks: `STTTRANS_DEBUG=1`, `STTTRANS_AUTOSTART=1`, `STTTRANS_TEST_FILE=<audio>`,
`STTTRANS_SNAPSHOT_DIR=<dir>` (PNG of each window every 2 s), `STTTRANS_OVERLAY_FULLSCREEN=1`,
`STTTRANS_MINUTES_CHUNK=<chars>` (force the chunked minutes path), `STTTRANS_NO_KEYCHAIN=1` (keys in memory only),
`STTTRANS_FAIL_TRANSLATIONS=<n>` / `STTTRANS_TRANSLATE_DELAY=<sec>` (inject translation faults / backlog),
`STTTRANS_AUTO_RECOVER=restore|discard` (answer the crash-recovery prompt). With `STTTRANS_TEST_FILE` the app stops itself at the end of the file.
