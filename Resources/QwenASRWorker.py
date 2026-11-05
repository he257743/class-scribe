"""Local PCM -> English worker. No audio files, network requests or microphone access.

Input: one JSON settings line, then mono little-endian float32 PCM at 16 kHz.
Output: bounded JSON lines. Closing stdin drains the remaining audio and exits.
Audio windows do not overlap: every captured sample belongs to one final window.
"""
from __future__ import annotations
import argparse
import array
from collections import deque
from dataclasses import dataclass
import json
import math
import os
import signal
import sys
import threading
import time

RATE = 16000
FRAME = 320  # 20 ms, used for boundary selection rather than word timestamps.

@dataclass(frozen=True)
class AudioJob:
    start: int
    end: int
    pcm: bytes
    final: bool

class Segmenter:
    """Bounded, non-overlapping windows; previews are replaceable snapshots."""
    def __init__(self):
        self.buffer = bytearray()
        self.remainder = bytearray()
        self.start = 0
        self.quiet = 0
        self.preview_at = 0

    @staticmethod
    def energy(pcm):
        samples = array.array('f')
        samples.frombytes(pcm)
        values = samples[::8]
        return math.sqrt(sum(float(x) ** 2 for x in values) / max(1, len(values)))

    def _commit(self, count):
        pcm = bytes(self.buffer[:count * 4])
        job = AudioJob(self.start, self.start + count, pcm, True)
        del self.buffer[:count * 4]
        self.start += count
        self.preview_at = 0
        self.quiet = 0
        for pos in range(0, len(self.buffer), FRAME * 4):
            block = self.buffer[pos:pos + FRAME * 4]
            self.quiet = self.quiet + len(block) // 4 if self.energy(block) < 0.004 else 0
        return job

    def feed(self, data):
        self.remainder.extend(data)
        jobs = []
        while len(self.remainder) >= FRAME * 4:
            block = self.remainder[:FRAME * 4]
            del self.remainder[:FRAME * 4]
            self.buffer.extend(block)
            self.quiet = self.quiet + FRAME if self.energy(block) < 0.004 else 0
            length = len(self.buffer) // 4
            if length >= 4 * RATE and self.quiet >= int(0.6 * RATE):
                count = max(2 * RATE, length - self.quiet + int(0.2 * RATE))
                jobs.append(self._commit(min(count, length)))
            elif length >= 12 * RATE:
                # Cut at a low-energy frame near the end. Carry the tail intact;
                # do not overlap windows or remove matching text heuristically.
                choices = range(length - int(1.5 * RATE), length, FRAME)
                count = min(choices, key=lambda i: self.energy(self.buffer[i * 4:(i + FRAME) * 4]))
                jobs.append(self._commit(count))
            elif length >= 3 * RATE and length - self.preview_at >= 3 * RATE:
                self.preview_at = length
                jobs.append(AudioJob(self.start, self.start + length, bytes(self.buffer), False))
        return jobs

    def finish(self):
        if len(self.remainder) % 4:
            raise ValueError('Truncated float32 audio input')
        self.buffer.extend(self.remainder)
        self.remainder.clear()
        return [self._commit(len(self.buffer) // 4)] if self.buffer else []

class JobQueue:
    def __init__(self):
        self.condition = threading.Condition()
        self.finals = deque()
        self.preview = None
        self.closed = False
        self.problem = None

    def push(self, job):
        with self.condition:
            if job.final:
                if len(self.finals) >= 4:
                    raise BufferError('识别积压过多，已停止以避免静默漏字。请关闭其他高负载程序后继续。')
                self.finals.append(job)
                if self.preview and self.preview.start <= job.start:
                    self.preview = None
            else:
                self.preview = job
            self.condition.notify()

    def close(self, problem=None):
        with self.condition:
            self.closed = True
            self.problem = problem
            self.condition.notify_all()

    def take(self):
        with self.condition:
            while not self.finals and not self.preview and not self.closed:
                self.condition.wait()
            if self.problem:
                raise self.problem
            if self.finals:
                return self.finals.popleft()
            if self.preview:
                job, self.preview = self.preview, None
                return job
            return None

def looks_like_prompt_echo(text):
    normalized = ' '.join(text.lower().split())
    return 'transcribe the english lecture faithfully' in normalized and 'technical vocabulary:' in normalized

class SpeechGate:
    """Screen whole windows for voice, while retaining original audio elsewhere.

    A fresh detector per snapshot avoids replaying the same preview into a VAD's
    adaptive state. No samples are removed from a window that passes the gate.
    """
    def __init__(self, factory):
        self.factory = factory

    def voiced_frames(self, pcm):
        samples = array.array('f'); samples.frombytes(pcm)
        if any(not math.isfinite(value) for value in samples):
            raise ValueError('音频包含无效采样，已停止，请检查输入设备。')
        quantized = array.array('h', (round(max(-1, min(1, value)) * 32767) for value in samples)).tobytes()
        detector = self.factory(2)
        voiced = 0
        longest = run = 0
        size = FRAME * 2
        for offset in range(0, len(quantized), size):
            frame = quantized[offset:offset + size].ljust(size, b'\0')
            yes = detector.is_speech(frame, RATE)
            voiced += yes
            run = run + 1 if yes else 0
            longest = max(longest, run)
        return voiced, longest

    def contains_speech(self, pcm):
        voiced, longest = self.voiced_frames(pcm)
        return voiced >= 8 and longest >= 5

def model_events(model, audio):
    # ASR context is not an instruction-following chat prompt. Passing the
    # instruction and full glossary caused 1.6.0 to transcribe its own prompt.
    return model.stream_transcribe(audio, language='English', max_tokens=384,
        temperature=0.0, chunk_duration=15, verbose=False, system_prompt=None)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    output = sys.stdout
    lock = threading.Lock()
    def emit(**message):
        with lock:
            output.write(json.dumps(message, ensure_ascii=False) + '\n')
            output.flush()
    try:
        settings = json.loads(sys.stdin.buffer.readline(65536))
        terms = settings.get('terms', [])
        if not isinstance(terms, list) or len(terms) > 100 or any(not isinstance(x, str) or len(x) > 80 for x in terms):
            raise ValueError('Invalid terminology settings')
        os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
        import contextlib
        import resource
        import numpy as np
        import webrtcvad
        import mlx.core as mx
        from mlx_audio.stt import load
        mx.set_cache_limit(128 * 1024 * 1024)
        began = time.monotonic()
        with contextlib.redirect_stdout(sys.stderr):
            model = load(args.model)
        emit(kind='ready', model_load_seconds=time.monotonic() - began)
        jobs = JobQueue()
        def ingest():
            segmenter = Segmenter()
            try:
                while True:
                    block = sys.stdin.buffer.read1(65536)
                    if not block:
                        break
                    for job in segmenter.feed(block):
                        jobs.push(job)
                for job in segmenter.finish():
                    jobs.push(job)
                jobs.close()
            except BaseException as error:
                jobs.close(error)
        threading.Thread(target=ingest, daemon=True).start()
        gate = SpeechGate(webrtcvad.Vad)
        while (job := jobs.take()) is not None:
            # Energy alone classified ordinary microphone noise as speech.
            # The capture file remains intact even when this window is skipped.
            if Segmenter.energy(job.pcm) < 0.00001 or not gate.contains_speech(job.pcm):
                continue
            began = time.monotonic()
            text = ''
            last_emit = began
            first = None
            tokens = 0
            with contextlib.redirect_stdout(sys.stderr):
                for event in model_events(model, np.frombuffer(job.pcm, dtype='<f4').copy()):
                    if jobs.problem:
                        raise jobs.problem
                    if event.text:
                        tokens += 1
                        text += event.text
                        if first is None:
                            first = time.monotonic() - began
                        if len(text) > 6000:
                            raise ValueError('识别结果异常过长，已停止并保留原音。')
                        if looks_like_prompt_echo(text):
                            raise ValueError('检测到识别器回显内部提示，已停止输出异常文字，请保留原音回听。')
                        now = time.monotonic()
                        if now - last_emit >= 0.2 and text.strip():
                            emit(kind='result', start=job.start / RATE, end=job.end / RATE,
                                text=text.strip(), final=False)
                            last_emit = now
            if tokens >= 384:
                raise ValueError('识别达到本段长度上限，可能有遗漏；已停止，请回听原音。')
            if text.strip():
                emit(kind='result', start=job.start / RATE, end=job.end / RATE,
                    text=text.strip(), final=job.final, processing_seconds=time.monotonic() - began,
                    first_token_seconds=first, peak_mlx_bytes=mx.get_peak_memory(),
                    worker_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
            mx.clear_cache()
        emit(kind='stopped', worker_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            worker_cpu_seconds=resource.getrusage(resource.RUSAGE_SELF).ru_utime + resource.getrusage(resource.RUSAGE_SELF).ru_stime)
    except BaseException as error:
        emit(kind='error', message=str(error)[:500])
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
