#!/usr/bin/env bash
set -euo pipefail

# Compile the actual app services against the same WhisperKit version used by
# Xcode. Synthetic speech contains no user recordings or personal information.
SMOKE_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/zhfr-language-smoke.XXXXXX")
trap 'rm -rf "$SMOKE_DIR"' EXIT
mkdir -p "$SMOKE_DIR/Sources/ZHFRSmoke" "$SMOKE_DIR/audio"
cat > "$SMOKE_DIR/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ZHFRSmoke", platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "0.17.0")],
    targets: [.executableTarget(name: "ZHFRSmoke", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])])
PACKAGE
cp ZHFRLive/Models/TranscriptLine.swift "$SMOKE_DIR/Sources/ZHFRSmoke/"
for SERVICE in RecognitionOptions BilingualWhisperTokenizer LanguageDetector SentenceAssembler MicrophoneSignalProcessor PhraseTranslator RealtimeTranslationSocket PCMConverter TranslationEventBuffer; do
  cp "ZHFRLive/Services/$SERVICE.swift" "$SMOKE_DIR/Sources/ZHFRSmoke/"
done
cp Tests/ASRSmoke.swift "$SMOKE_DIR/Sources/ZHFRSmoke/main.swift"

VOICE_LIST=$(/usr/bin/say -v '?')
FRENCH_VOICE=$(awk '$2 == "fr_FR" { print $1; exit }' <<< "$VOICE_LIST")
if awk '$1 == "Thomas" && $2 == "fr_FR" { found = 1 } END { exit !found }' <<< "$VOICE_LIST"; then FRENCH_VOICE=Thomas; fi
CHINESE_VOICE=$(awk '$2 == "zh_CN" { print $1; exit }' <<< "$VOICE_LIST")
if [ -z "$FRENCH_VOICE" ] || [ -z "$CHINESE_VOICE" ]; then
  echo 'Required French and Chinese system voices are unavailable.'
  exit 1
fi
echo "Synthetic voices: French=$FRENCH_VOICE, Chinese=$CHINESE_VOICE"
/usr/bin/say -v "$FRENCH_VOICE" -r 145 -o "$SMOKE_DIR/audio/fr.aiff" "Bonjour tout le monde. Aujourd'hui, nous étudions les mathématiques."
/usr/bin/say -v "$CHINESE_VOICE" -r 145 -o "$SMOKE_DIR/audio/zh.aiff" '今天是星期一。我在法国学习计算机。'
# Feed exactly the format recorded by the app. Avoid the SDK file-resampling
# path: the app uses its own AVAudioConverter before Whisper sees any audio.
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$SMOKE_DIR/audio/fr.aiff" "$SMOKE_DIR/audio/fr.wav"
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$SMOKE_DIR/audio/zh.aiff" "$SMOKE_DIR/audio/zh.wav"
# Independent natural-speech control, from OpenAI Whisper's public fixture.
curl --fail --location --silent --show-error --max-time 30 'https://raw.githubusercontent.com/openai/whisper/main/tests/jfk.flac' -o "$SMOKE_DIR/audio/jfk.flac"
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$SMOKE_DIR/audio/jfk.flac" "$SMOKE_DIR/audio/jfk.wav"
swift run --package-path "$SMOKE_DIR" -c release ZHFRSmoke "$SMOKE_DIR/audio"
