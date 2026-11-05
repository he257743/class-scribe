"""Deterministic audio scheduling/protocol checks; no MLX dependency or microphone."""
import array
import math
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
from QwenASRWorker import Segmenter, JobQueue, AudioJob, RATE, SpeechGate, looks_like_prompt_echo, model_events, recognition_issue, recognize_window, token_budget, recognition_window_setting

class FixtureTokenizer:
    def __init__(self, pieces):self.pieces = pieces
    def decode(self, ids, skip_special_tokens=True):
        return b''.join(self.pieces[int(i)] for i in ids).decode('utf-8', errors='replace')

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

class RecognitionGuardTests(unittest.TestCase):
    def test_asr_never_receives_an_instruction_or_glossary_prompt(self):
        class Model:
            def stream_generate(self, audio, **kwargs):
                self.options = kwargs
                return iter([(1, None)])
        model = Model()
        self.assertEqual(list(model_events(model, [0.0])), [(1, None)])
        self.assertIsNone(model.options['system_prompt'])
        self.assertNotIn('Technical vocabulary', str(model.options))

    def test_known_prompt_echo_is_distinguished_from_normal_technical_speech(self):
        self.assertTrue(looks_like_prompt_echo('Transcribe the English lecture faithfully. Technical vocabulary: mutex, thread.'))
        self.assertFalse(looks_like_prompt_echo('A mutex protects the shared resource.'))
        self.assertFalse(looks_like_prompt_echo('The technical vocabulary includes mutex and thread.'))
        self.assertFalse(looks_like_prompt_echo('mutex, mutual exclusion, critical section, semaphore, deadlock, thread, process, scheduler'))

    def test_transient_noise_bursts_do_not_count_as_continuous_speech(self):
        class VAD:
            def __init__(self, mode):self.index = 0
            def is_speech(self, frame, rate):
                self.index += 1
                return self.index % 8 < 4
        pcm = array.array('f', [0.01] * (16000)).tobytes()
        self.assertFalse(SpeechGate(VAD).contains_speech(pcm))

    def test_detected_speech_preserves_whole_windows_and_pcm_format(self):
        seen = []
        class VAD:
            def __init__(self, mode):pass
            def is_speech(self, frame, rate):
                seen.append((len(frame), rate)); return True
        pcm = array.array('f', [0.01] * 4001).tobytes()
        original = pcm
        self.assertTrue(SpeechGate(VAD).contains_speech(pcm))
        self.assertEqual(pcm, original)
        self.assertTrue(all(size == 640 and rate == 16000 for size, rate in seen))

    def test_invalid_audio_samples_are_rejected(self):
        class VAD:
            def __init__(self, mode):pass
        with self.assertRaises(ValueError):
            SpeechGate(VAD).contains_speech(array.array('f', [float('nan')]).tobytes())


class RunawayRecognitionTests(unittest.TestCase):
    def test_phrase_loop_is_flagged_at_impossible_density(self):
        self.assertEqual(recognition_issue('An example packet crossed the network, ' * 64, 9), 'repetition')

    def test_single_word_loop_after_valid_prefix_is_flagged(self):
        self.assertEqual(recognition_issue("We are going to the lab. " + 'yeah, ' * 185, 28), 'repetition')

    def test_normal_repetition_and_slow_practice_are_preserved(self):
        for text,seconds in [('No, no, no. Do not unlock the mutex.', 3),
                ('The packet is sent. ' * 3, 10), ('An example packet crossed the network. ' * 10, 60)]:
            self.assertIsNone(recognition_issue(text,seconds))

    def test_token_limit_is_proportional_but_allows_fast_technical_speech(self):
        self.assertEqual(token_budget(3),80)
        self.assertGreaterEqual(token_budget(12),200)
        self.assertLessEqual(token_budget(12),384)

    def test_runaway_stream_closes_early_and_next_call_still_succeeds(self):
        class Model:
            calls = 0
            closed = 0
            emitted = 0
            def stream_generate(self,audio,**kwargs):
                self.calls += 1
                try:
                    words = ['from '] * 1000 if self.calls == 1 else ['A ', 'mutex ', 'protects ', 'the ', 'resource.']
                    self._tokenizer = FixtureTokenizer([w.encode() for w in words])
                    for index in range(len(words)):
                        self.emitted += 1
                        yield index, None
                finally:
                    self.closed += 1
        model=Model();audio=[0.01] * (3 * RATE)
        first=recognize_window(model,audio)
        self.assertEqual(first['issue'],'repetition')
        self.assertLess(model.emitted,100)
        second=recognize_window(model,audio)
        self.assertIsNone(second['issue'])
        self.assertEqual(second['text'],'A mutex protects the resource.')
        self.assertEqual(model.closed,2)

    def test_reported_budget_exhaustion_is_not_a_normal_result(self):
        class Model:
            def stream_generate(self,audio,**kwargs):
                self._tokenizer = FixtureTokenizer([b'.'] * kwargs['max_tokens'])
                for index in range(kwargs['max_tokens']):yield index, None
        self.assertEqual(recognize_window(Model(),[0.0] * RATE)['issue'],'generationLimit')

    def test_cancellation_closes_the_generation_iterator(self):
        class Model:
            closed = False
            def stream_generate(self,audio,**kwargs):
                try:
                    self._tokenizer = FixtureTokenizer([b'word'])
                    yield 0, None
                finally:
                    self.closed=True
        model=Model()
        with self.assertRaisesRegex(RuntimeError,'overloaded'):
            recognize_window(model,[0.1]*RATE,lambda:RuntimeError('overloaded'))
        self.assertTrue(model.closed)

class ContextWindowTests(unittest.TestCase):
    def test_thirty_second_stop_keeps_one_complete_window(self):
        source = array.array('f', (0.1 * math.sin(i * .1) for i in range(30 * RATE))).tobytes()
        segmenter = Segmenter(30)
        jobs = segmenter.feed(source)
        self.assertFalse(any(x.final for x in jobs))
        finals = segmenter.finish()
        self.assertEqual(len(finals), 1)
        self.assertEqual(finals[0].pcm, source)
        self.assertEqual(finals[0].end, 30 * RATE)

    def test_context_windows_preserve_all_samples_with_lookahead(self):
        source = array.array('f', (0.1 * math.sin(i * .13) for i in range(69 * RATE + 171))).tobytes()
        segmenter = Segmenter(30);jobs=[]
        for offset in range(0, len(source), 7913):jobs.extend(segmenter.feed(source[offset:offset+7913]))
        jobs.extend(segmenter.finish());finals=[x for x in jobs if x.final]
        self.assertEqual(b''.join(x.pcm for x in finals),source)
        self.assertTrue(all(x.end-x.start<=31.5*RATE for x in finals))
        self.assertTrue(all(a.end==b.start for a,b in zip(finals,finals[1:])))
        self.assertTrue(any(not x.final and x.end==3*RATE for x in jobs))

    def test_context_mode_does_not_force_two_second_quiet_chunks(self):
        source=array.array('f',[.0001]*(9*RATE)).tobytes()
        segmenter=Segmenter(30);jobs=segmenter.feed(source)+segmenter.finish()
        finals=[x for x in jobs if x.final]
        self.assertEqual(finals[0].end,6*RATE)
        self.assertEqual(b''.join(x.pcm for x in finals),source)

    def test_only_supported_window_settings_are_accepted(self):
        self.assertEqual(recognition_window_setting({}),12)
        self.assertEqual(recognition_window_setting({'window_seconds':30}),30)
        self.assertEqual(recognition_window_setting({'window_seconds':12}),12)
        for value in [True,0,13,30.0,100,None,'30']:
            with self.assertRaises(ValueError):recognition_window_setting({'window_seconds':value})

    def test_complete_prefix_decoding_preserves_split_utf8(self):
        class Model:
            _tokenizer=FixtureTokenizer([b'\xe9',b'\xbe\x98'])
            def stream_generate(self,audio,**kwargs):
                yield 0,None
                yield 1,None
        result=recognize_window(Model(),[.1]*RATE)
        self.assertEqual(result['text'],'龘')
        self.assertIsNone(result['issue'])

    def test_incomplete_final_character_is_reviewed(self):
        class Model:
            _tokenizer=FixtureTokenizer([b'\xe9'])
            def stream_generate(self,audio,**kwargs):yield 0,None
        result=recognize_window(Model(),[.1]*RATE)
        self.assertEqual(result['issue'],'invalidEncoding')
        self.assertEqual(result['text'],'\ufffd')

if __name__ == '__main__':unittest.main()
