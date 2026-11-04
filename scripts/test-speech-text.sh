#!/bin/bash
# Fast deterministic speech-text regressions: no models, microphone or server needed.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" \
    Sources/SpeakToMe/SSML.swift Sources/SpeakToMe/SentenceChunker.swift \
    Tests/Regression/SentenceChunkerRegression.swift -o "$TEST_DIR/speech-text-tests"
"$TEST_DIR/speech-text-tests"
