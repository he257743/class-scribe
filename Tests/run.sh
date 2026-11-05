#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p /private/tmp/classscribe-module-cache "$TASK_ROOT/build"
export CLASSSCRIBE_TEST_DOCX="$TASK_ROOT/build/export-test.docx"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path /private/tmp/classscribe-module-cache \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Tests/TranscriptTests.swift" -o "$TASK_ROOT/build/transcript-tests"
"$TASK_ROOT/build/transcript-tests"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path /private/tmp/classscribe-module-cache \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/AppModel.swift" \
    "$TASK_ROOT/Tests/DeletionTests.swift" -o "$TASK_ROOT/build/deletion-tests"
"$TASK_ROOT/build/deletion-tests"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path /private/tmp/classscribe-module-cache \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/AppModel.swift" \
    "$TASK_ROOT/Tests/ParagraphTests.swift" -o "$TASK_ROOT/build/paragraph-tests"
"$TASK_ROOT/build/paragraph-tests"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path /private/tmp/classscribe-module-cache \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/AppModel.swift" \
    "$TASK_ROOT/Tests/LivePreviewTests.swift" -o "$TASK_ROOT/build/live-preview-tests"
"$TASK_ROOT/build/live-preview-tests"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path /private/tmp/classscribe-module-cache \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/AppModel.swift" \
    "$TASK_ROOT/Tests/PauseTests.swift" -o "$TASK_ROOT/build/pause-tests"
"$TASK_ROOT/build/pause-tests"
