#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
zsh "$TASK_ROOT/Tests/compile-backend-comparison.sh"
/usr/bin/say -v Samantha -r 145 -o "$TASK_ROOT/build/qwen-short-fixture.aiff" \
 'A mutex protects the shared resource. Only one thread may enter the critical section at a time.'
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$TASK_ROOT/build/qwen-short-fixture.aiff" "$TASK_ROOT/build/qwen-short-fixture.wav"
"$TASK_ROOT/build/native-backend-comparison" qwen "$TASK_ROOT/build/qwen-short-fixture.wav" \
 "$TASK_ROOT/Resources/QwenASRWorker.py" "$TASK_ROOT/build/qwen-lifecycle.json" --pause-test
