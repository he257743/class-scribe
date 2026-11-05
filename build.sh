#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASK_STAGE="$(mktemp -d /private/tmp/classscribe-build.XXXXXX)"
TASK_APP="$TASK_STAGE/听课译记.app"
TASK_CACHE="/private/tmp/classscribe-module-cache"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_CACHE" "$TASK_ROOT/build"
xcrun swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$TASK_CACHE" \
    -target arm64-apple-macos26.0 "$TASK_ROOT"/Sources/*.swift \
    -o "$TASK_APP/Contents/MacOS/ClassScribe"
cp "$TASK_ROOT/Resources/QwenASRWorker.py" "$TASK_ROOT/Resources/PrepareQwenASR.py" \
    "$TASK_ROOT/Resources/qwen-asr-requirements.txt" "$TASK_APP/Contents/Resources/"
cp "$TASK_ROOT/Info.plist" "$TASK_APP/Contents/Info.plist"
if [[ -f "$TASK_ROOT/Assets/AppIcon.icns" ]]; then
    cp "$TASK_ROOT/Assets/AppIcon.icns" "$TASK_APP/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$TASK_APP"
codesign --force --sign - --identifier local.classscribe.mac --options runtime \
    --entitlements "$TASK_ROOT/entitlements.plist" "$TASK_APP"
codesign --verify --strict "$TASK_APP"
mkdir -p "$TASK_ROOT/dist"
TASK_PYTHON="${CLASSSCRIBE_PYTHON:-/usr/bin/python3}"
"$TASK_PYTHON" "$TASK_ROOT/package.py" "$TASK_APP" "$TASK_ROOT/dist/听课译记.zip"
print -r -- "$TASK_APP" > "$TASK_ROOT/build/latest-app-path.txt"
print -r -- "$TASK_APP"
