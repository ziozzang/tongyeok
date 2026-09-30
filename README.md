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

## Install

1. Download `tongyeok_<version>_macos_arm64.zip` from [Releases](https://github.com/ziozzang/tongyeok/releases/latest) and unzip.
2. Move **Tongyeok.app** to `/Applications` (or `~/Applications`).
3. The app is ad-hoc signed (not notarized). On first launch either right-click → **Open**, or run
   `xattr -dr com.apple.quarantine /Applications/Tongyeok.app`

Requirements: macOS 26 (Tahoe) or later, Apple Silicon.

## Updates

The app checks GitHub Releases once a day (and via **Check for Updates…**). Updates are verified against the
release's `SHA256SUMS`, installed in place and the app relaunches. Set `NO_UPDATE_CHECK=1` to disable.

## Build & release

```sh
./build.sh                         # → build/Tongyeok.app  (plain swiftc, no Xcode project)
scripts/release.sh 0.2.0 "notes"   # bump version, build, zip + SHA256SUMS, tag, push, GitHub release
```
Release assets follow the same scheme as [sugyeol](https://github.com/ziozzang/sugyeol):
`tongyeok_<version>_macos_arm64.zip` + `SHA256SUMS`.
## Tests

```sh
xcrun swiftc -target arm64-apple-macosx26.0 -o build/unit Tests/unit/main.swift Sources/Shared/SentenceAssembler.swift && build/unit
xcrun swiftc -O -target arm64-apple-macosx26.0 -o build/cli Tests/cli/main.swift \
  Sources/App/{SpeechEngine,AudioSource}.swift Sources/Shared/{Common,Translator,SentenceAssembler,VAD}.swift
say -o /tmp/t.aiff "Hello everyone. [[slnc 1500]] Let's begin." && STTTRANS_DEBUG=1 build/cli /tmp/t.aiff en-US google ko
```
Debug hooks: `STTTRANS_DEBUG=1`, `STTTRANS_AUTOSTART=1`, `STTTRANS_TEST_FILE=<audio>`.
