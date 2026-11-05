"""Optional same-audio regression for runaway decoding; no microphone or private text output."""
from pathlib import Path
import argparse
import importlib.util
import json

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native_worker_checks',root/'Tests/run-qwen-no-speech.py')
checks=importlib.util.module_from_spec(spec);spec.loader.exec_module(checks)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--problem-audio',type=Path,required=True)
    parser.add_argument('--baseline-worker',type=Path)
    args=parser.parse_args()
    build=root/'build';build.mkdir(exist_ok=True)
    install=Path.home()/'Library/Application Support/ClassScribe/QwenASR'
    python=install/'runtime/bin/python3.12';model=install/'model'
    problem=checks.wav_pcm(args.problem_audio)
    clear=checks.wav_pcm(build/'qwen-short-fixture.wav')
    reports=[]
    def record(name,result,passed,private):
        reports.append({'name':name,'passed':passed,'private_audio':private,
            **{k:v for k,v in result.items() if k!='final_text'}})
        print(('PASS: ' if passed else 'FAIL: ')+name+
            '; rejected='+str(result['rejected_events'])+'; unsafe subtitles='+str(result['unsafe_result_events']),flush=True)
    if args.baseline_worker:
        result=checks.run(python,model,args.baseline_worker,problem,[],build/'repetition-baseline.log')
        record('original loop reproduced',result,result['unsafe_result_events']>0,True)
    for name,pcm in [('same problem audio',problem),('problem followed by clear English',problem+b'\0'*(2*16000*4)+clear)]:
        result=checks.run(python,model,root/'Resources/QwenASRWorker.py',pcm,[],build/('repetition-'+str(len(reports))+'.log'))
        passed=result['normal_exit'] and result['stopped'] and result['error_events']==0 and result['unsafe_result_events']==0
        if name=='problem followed by clear English':
            passed=passed and 'mutex' in result['final_text'].lower() and 'critical section' in result['final_text'].lower()
        record(name,result,passed,True)
    report={'app_version':'1.6.2','all_passed':all(x['passed'] for x in reports),
        'microphone_used':False,'private_audio_or_text_published':False,'cases':reports}
    (build/'qwen-repetition-regression.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['all_passed']:raise SystemExit(1)
if __name__=='__main__':main()
