#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_CACHE=/private/tmp/classscribe-module-cache
mkdir -p "$TASK_CACHE" "$TASK_ROOT/build"
export CLASSSCRIBE_TEST_DOCX="$TASK_ROOT/build/export-test.docx"
TASK_SOURCES=(
  "$TASK_ROOT/Sources/Transcript.swift"
  "$TASK_ROOT/Sources/QwenSpeechEngine.swift"
  "$TASK_ROOT/Sources/QwenASRAssets.swift"
  "$TASK_ROOT/Sources/ContextReview.swift"
  "$TASK_ROOT/Sources/LocalSpeechEngine.swift"
  "$TASK_ROOT/Sources/LocalContextService.swift"
  "$TASK_ROOT/Sources/AppModel.swift"
)
for TASK_SUITE in Transcript Deletion Paragraph LivePreview Pause ContextReview SpeechBackend; do
  TASK_TEST_BINARY="$TASK_ROOT/build/${TASK_SUITE}-tests"
  xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$TASK_CACHE" \
    -target arm64-apple-macos26.0 "${TASK_SOURCES[@]}" \
    "$TASK_ROOT/Tests/${TASK_SUITE}Tests.swift" -o "$TASK_TEST_BINARY"
  "$TASK_TEST_BINARY"
done

/usr/bin/python3 "$TASK_ROOT/Tests/QwenWorkerTests.py"
