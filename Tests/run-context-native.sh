#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/build" /private/tmp/classscribe-module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -module-cache-path /private/tmp/classscribe-module-cache -target arm64-apple-macos26.0 \
  "$TASK_ROOT/Sources/Transcript.swift" "$TASK_ROOT/Sources/ContextReview.swift" \
  "$TASK_ROOT/Sources/LocalSpeechEngine.swift" "$TASK_ROOT/Sources/LocalContextService.swift" \
  "$TASK_ROOT/Sources/AppModel.swift" "$TASK_ROOT/Tests/NativeContextReviewTest.swift" -o "$TASK_ROOT/build/native-context-test"
"$TASK_ROOT/build/native-context-test" "$TASK_ROOT/build/native-context-test.json"
