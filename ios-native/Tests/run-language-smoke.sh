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
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")],
    targets: [.executableTarget(name: "ZHFRSmoke", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])])
PACKAGE
cp ZHFRLive/Models/TranscriptLine.swift "$SMOKE_DIR/Sources/ZHFRSmoke/"
for SERVICE in RecognitionOptions BilingualWhisperTokenizer LanguageDetector SentenceAssembler MicrophoneSignalProcessor PhraseTranslator RealtimeTranslationSocket PCMConverter TranslationEventBuffer; do
  cp "ZHFRLive/Services/$SERVICE.swift" "$SMOKE_DIR/Sources/ZHFRSmoke/"
done
cp Tests/ASRSmoke.swift "$SMOKE_DIR/Sources/ZHFRSmoke/main.swift"

VOICE_LIST=$(/usr/bin/say -v '?')
FRENCH_VOICE=$(awk '$2 == "fr_FR" { print $1; exit }' <<< "$VOICE_LIST")
CHINESE_VOICE=$(awk '$2 == "zh_CN" { print $1; exit }' <<< "$VOICE_LIST")
if [ -z "$FRENCH_VOICE" ] || [ -z "$CHINESE_VOICE" ]; then
  echo 'Required French and Chinese system voices are unavailable.'
  exit 1
fi
/usr/bin/say -v "$FRENCH_VOICE" -r 145 -o "$SMOKE_DIR/audio/fr.aiff" "Bonjour. Je m'appelle Marie. J'étudie l'informatique à Poitiers."
/usr/bin/say -v "$CHINESE_VOICE" -r 145 -o "$SMOKE_DIR/audio/zh.aiff" '今天是星期一。我在法国学习计算机。'
swift run --package-path "$SMOKE_DIR" -c release ZHFRSmoke "$SMOKE_DIR/audio"
