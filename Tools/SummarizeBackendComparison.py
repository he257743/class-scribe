"""Summarize only the explicitly synthetic comparison, never private transcripts."""
from pathlib import Path
import json
import re
import sys

def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower())

def edit_counts(reference, hypothesis):
    a, b = words(reference), words(hypothesis)
    rows = [list(range(len(b) + 1))]
    for i, x in enumerate(a, 1):
        row = [i]
        for j, y in enumerate(b, 1):
            row.append(min(row[-1] + 1, rows[-1][j] + 1, rows[-1][j-1] + (x != y)))
        rows.append(row)
    i, j = len(a), len(b)
    substitutions = deletions = insertions = 0
    while i or j:
        if i and j and rows[i][j] == rows[i-1][j-1] + (a[i-1] != b[j-1]):
            substitutions += a[i-1] != b[j-1]; i -= 1; j -= 1
        elif i and rows[i][j] == rows[i-1][j] + 1:
            deletions += 1; i -= 1
        else:
            insertions += 1; j -= 1
    return {'reference_words': len(a), 'substitutions': substitutions, 'deletions': deletions,
            'insertions': insertions, 'wer': rows[-1][-1] / max(1, len(a))}

if __name__ == '__main__':
    root, output = Path(sys.argv[1]), Path(sys.argv[2])
    reference = (root / 'backend-reference.txt').read_text().strip()
    runs = []
    for backend in ['apple', 'qwen']:
        run = json.loads((root / ('backend-' + backend + '.json')).read_text())
        if run['private_classroom_audio_used'] or run['status'] != 'pass':
            raise SystemExit('Refusing to publish private or failed runs')
        run['word_errors'] = edit_counts(reference, run['english'])
        runs.append(run)
    report = {'sample': 'one fixed synthetic English development sample, Samantha voice, 150 words/min',
        'reference': reference, 'runs': runs, 'microphone_used': False,
        'independent_accuracy_benchmark': False, 'context_review_enabled': False,
        'limitations': ['Single synthetic voice and single run per engine; no classroom WER is established.',
            'WER ignores punctuation and capitalization; it does not evaluate Chinese translation quality.',
            'First-text latency is measured from paced file capture; startup is reported separately.',
            'Host RSS excludes Apple system services. Worker RSS is not total unified-memory usage; Metal is reported separately and may overlap RSS.',
            'Metal allocations and RSS overlap in unified memory and must not be added into a total RAM figure.']}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    for run in runs:
        print(run['backend'], 'WER', round(run['word_errors']['wer'] * 100, 2), '%',
            'first EN', round(run['first_english_seconds'], 2), 'first ZH', round(run['first_chinese_seconds'], 2))
