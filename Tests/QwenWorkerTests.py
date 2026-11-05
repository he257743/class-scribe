"""Deterministic audio scheduling/protocol checks; no MLX dependency or microphone."""
import array
import math
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
from QwenASRWorker import Segmenter, JobQueue, AudioJob, RATE

class SegmenterTests(unittest.TestCase):
    def test_irregular_packet_sizes_preserve_every_sample_once(self):
        source = array.array('f', (0.1 * math.sin(i * 0.1) for i in range(29 * RATE + 139))).tobytes()
        segmenter = Segmenter(); jobs = []
        for pos in range(0, len(source), 7913):
            jobs.extend(segmenter.feed(source[pos:pos + 7913]))
        jobs.extend(segmenter.finish())
        finals = [job for job in jobs if job.final]
        self.assertEqual(b''.join(job.pcm for job in finals), source)
        self.assertEqual(finals[0].start, 0)
        self.assertEqual(finals[-1].end, len(source) // 4)
        for left, right in zip(finals, finals[1:]):self.assertEqual(left.end, right.start)
        self.assertTrue(all(job.end - job.start <= 12 * RATE for job in finals))

    def test_partial_utterance_is_flushed_on_stop(self):
        source = array.array('f', [0.01] * 2000).tobytes()
        segmenter = Segmenter(); self.assertEqual(segmenter.feed(source), [])
        jobs = segmenter.finish(); self.assertEqual(len(jobs), 1)
        self.assertTrue(jobs[0].final); self.assertEqual(jobs[0].pcm, source)

    def test_quiet_material_is_not_discarded_by_boundary_threshold(self):
        source = array.array('f', [0.0001] * (7 * RATE)).tobytes()
        segmenter = Segmenter(); jobs = segmenter.feed(source) + segmenter.finish()
        self.assertEqual(b''.join(job.pcm for job in jobs if job.final), source)
        self.assertGreater(Segmenter.energy(source), 0.00001)

    def test_preview_waits_for_audio_then_keeps_same_start(self):
        segmenter = Segmenter()
        self.assertEqual(segmenter.feed(array.array('f', [0.1] * (2 * RATE)).tobytes()), [])
        first = segmenter.feed(array.array('f', [0.1] * RATE).tobytes())
        self.assertEqual(len(first), 1); self.assertFalse(first[0].final)
        self.assertEqual(first[0].start, 0); self.assertEqual(first[0].end, 3 * RATE)
        last = segmenter.finish()[0]; self.assertEqual(last.start, first[0].start); self.assertTrue(last.final)

    def test_truncated_pcm_is_an_error(self):
        segmenter = Segmenter(); segmenter.feed(b'\0')
        with self.assertRaises(ValueError):segmenter.finish()

    def test_final_jobs_precede_latest_preview(self):
        queue = JobQueue()
        queue.push(AudioJob(0, 3, b'old', False))
        queue.push(AudioJob(0, 6, b'new', False))
        queue.push(AudioJob(0, 8, b'final', True))
        queue.push(AudioJob(8, 10, b'tail', False))
        queue.close()
        self.assertEqual(queue.take().pcm, b'final')
        self.assertEqual(queue.take().pcm, b'tail')
        self.assertIsNone(queue.take())

    def test_overload_reports_failure_instead_of_losing_audio(self):
        queue = JobQueue()
        for i in range(4):queue.push(AudioJob(i, i + 1, b'', True))
        with self.assertRaises(BufferError):queue.push(AudioJob(4, 5, b'', True))
        queue.close(RuntimeError('overloaded'))
        with self.assertRaisesRegex(RuntimeError, 'overloaded'):queue.take()

if __name__ == '__main__':unittest.main()
