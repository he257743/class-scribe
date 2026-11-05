#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_CACHE=/private/tmp/classscribe-module-cache
mkdir -p "$TASK_CACHE" "$TASK_ROOT/build"
# Generate an explicit synthetic fixture; never use a classroom recording.
/usr/bin/say -v "${CLASSSCRIBE_TEST_VOICE:-Samantha}" -r 145 \
    -o "$TASK_ROOT/build/paragraph-fixture.aiff" \
    'A critical section is a part of a program that accesses a shared resource. A lock makes sure that only one thread enters the critical section at a time. Other threads must wait until the lock is released.'
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$TASK_CACHE" \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/AppModel.swift" \
    "$TASK_ROOT/Tests/NativeLivePreviewTest.swift" -Xlinker -sectcreate -Xlinker __TEXT \
    -Xlinker __info_plist -Xlinker "$TASK_ROOT/Info.plist" -o "$TASK_ROOT/build/native-live-preview-test"
"$TASK_ROOT/build/native-live-preview-test" "$TASK_ROOT/build/native-live-preview-test.json"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$TASK_CACHE" \
    -target arm64-apple-macos26.0 "$TASK_ROOT/Sources/Transcript.swift" \
    "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/AppModel.swift" \
    "$TASK_ROOT/Tests/NativeParagraphTest.swift" -Xlinker -sectcreate -Xlinker __TEXT \
    -Xlinker __info_plist -Xlinker "$TASK_ROOT/Info.plist" -o "$TASK_ROOT/build/native-paragraph-test"
"$TASK_ROOT/build/native-paragraph-test" "$TASK_ROOT/build/paragraph-fixture.aiff" "$TASK_ROOT/build/native-paragraph-test.json"
