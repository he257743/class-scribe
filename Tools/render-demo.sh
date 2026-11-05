#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/build" "$TASK_ROOT/docs/images" /private/tmp/classscribe-module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library \
    -module-cache-path /private/tmp/classscribe-module-cache -target arm64-apple-macos26.0 \
    "$TASK_ROOT/Sources/Transcript.swift" "$TASK_ROOT/Sources/QwenSpeechEngine.swift" "$TASK_ROOT/Sources/QwenASRAssets.swift" "$TASK_ROOT/Sources/LocalSpeechEngine.swift" \
    "$TASK_ROOT/Sources/ContextReview.swift" "$TASK_ROOT/Sources/LocalContextService.swift" \
    "$TASK_ROOT/Sources/AppModel.swift" "$TASK_ROOT/Sources/ContentView.swift" \
    "$TASK_ROOT/Tools/RenderDemo.swift" -o "$TASK_ROOT/build/render-demo"
"$TASK_ROOT/build/render-demo" "$TASK_ROOT/docs/images/demo.png"
