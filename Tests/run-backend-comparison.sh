#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/build" /private/tmp/classscribe-module-cache
# Fixed synthetic development sample; no private recording, no microphone.
TASK_REFERENCE='A mutex protects a shared resource. Mutual exclusion allows only one thread to enter a critical section at a time. A semaphore can allow several threads to access a limited number of resources. A deadlock occurs when processes wait for each other. Virtual memory uses page tables to map virtual addresses to physical memory. A page fault occurs when a required page is not in memory. In a computer network, a TCP port identifies a service. A router forwards packets between subnets. The cache stores frequently used data.'
print -r -- "$TASK_REFERENCE" > "$TASK_ROOT/build/backend-reference.txt"
/usr/bin/say -v Samantha -r 150 -o "$TASK_ROOT/build/backend-fixture.aiff" "$TASK_REFERENCE"
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$TASK_ROOT/build/backend-fixture.aiff" "$TASK_ROOT/build/backend-fixture.wav"
zsh "$TASK_ROOT/Tests/compile-backend-comparison.sh"
for TASK_BACKEND in apple qwen; do
 "$TASK_ROOT/build/native-backend-comparison" "$TASK_BACKEND" "$TASK_ROOT/build/backend-fixture.wav" \
  "$TASK_ROOT/Resources/QwenASRWorker.py" "$TASK_ROOT/build/backend-$TASK_BACKEND.json"
done
