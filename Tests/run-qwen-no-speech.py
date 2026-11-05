"""Optional real-model regression. No microphone; private input content is never printed."""
from pathlib import Path
import argparse
import array
import json
import math
import os
import queue
import random
import subprocess
import threading
import time
import wave
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1] / "Resources"))
from QwenASRWorker import recognition_issue

def wav_pcm(path):
    with wave.open(str(path)) as f:
        if (f.getframerate(),f.getnchannels(),f.getsampwidth()) != (16000,1,2):
            raise ValueError('Expected16kHz mono PCM16 WAV')
        source=array.array('h',f.readframes(f.getnframes()))
    return array.array('f',(x/32768 for x in source)).tobytes()

def echo(text):
    value=' '.join(text.lower().split())
    return 'transcribe the english lecture faithfully' in value and 'technical vocabulary:' in value

def run(python,model,worker,pcm,terms,log,pace=True,window_seconds=30):
    events=[];messages=queue.Queue()
    env=os.environ.copy();env.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1')
    with log.open('w') as errors:
        p=subprocess.Popen([str(python),'-I',str(worker),'--model',str(model)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,env=env)
        def read():
            try:
                for line in p.stdout:
                    value=json.loads(line);events.append(value);messages.put(value)
            except Exception as error:messages.put({'kind':'error','message':str(error)})
        reader=threading.Thread(target=read,daemon=True);reader.start()
        try:
            p.stdin.write((json.dumps({'terms':terms,'window_seconds':window_seconds})+'\n').encode());p.stdin.flush()
            ready=messages.get(timeout=90)
            if ready['kind']!='ready':raise RuntimeError(ready)
            began=time.monotonic()
            for offset in range(0,len(pcm),6400):
                if p.poll() is not None:break
                if pace:
                    remaining=began+(offset+min(6400,len(pcm)-offset))/64000-time.monotonic()
                    if remaining>0:time.sleep(remaining)
                try:p.stdin.write(pcm[offset:offset+6400]);p.stdin.flush()
                except BrokenPipeError:break
            try:p.stdin.close()
            except BrokenPipeError:pass
            p.wait(timeout=90);reader.join(timeout=2)
        finally:
            if p.poll() is None:p.terminate();p.wait(timeout=5)
    results=[x for x in events if x['kind']=='result']
    return {'result_events':len(results),'prompt_echo_events':sum(echo(x.get('text','')) for x in results),
            'error_events':sum(x['kind']=='error' for x in events),
            'rejected_events':sum(x['kind']=='rejected' for x in events),
            'unsafe_result_events':sum(recognition_issue(x.get('text',''),x['end']-x['start']) is not None for x in results),
            'final_issue_reasons':sorted(set(x.get('issue','') for x in events if x['kind']=='rejected' and x.get('final'))),'normal_exit':p.returncode==0,
            'stopped':any(x['kind']=='stopped' for x in events),
            'final_text':' '.join(x['text'] for x in results if x.get('final'))}

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--problem-audio',type=Path)
    parser.add_argument('--baseline-worker',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1];build=root/'build'
    install=Path.home()/'Library/Application Support/ClassScribe/QwenASR'
    python=install/'runtime/bin/python3.12';model=install/'model';worker=root/'Resources/QwenASRWorker.py'
    terms=['mutex','mutual exclusion','critical section','semaphore','deadlock','thread','process','scheduler',
        'context switch','virtual memory','page fault','cache','race condition','TCP','UDP','IP','packet','subnet',
        'router','port','socket','congestion control','flow control','routing table','throughput','data flow diagram',
        'DFD','pseudocode','coupling','cohesion','encapsulation','inheritance','polymorphism','operating system','synchronization']
    reports=[]
    if args.problem_audio and args.baseline_worker:
        data=wav_pcm(args.problem_audio)
        result=run(python,model,args.baseline_worker,data,terms,build/'baseline-echo.log')
        reports.append({'name':'original failure reproduced','passed':result['prompt_echo_events']>0,
            **{k:v for k,v in result.items() if k!='final_text'}})
        print('Baseline prompt echoes:',result['prompt_echo_events'],flush=True)
    rng=random.Random(17)
    cases=[('digital silence',array.array('f',[0.0]*(6*16000)).tobytes(),True),
        ('quiet white noise',array.array('f',(rng.gauss(0,.001) for _ in range(6*16000))).tobytes(),True),
        ('fan hum',array.array('f',(.002*math.sin(2*math.pi*60*i/16000) for i in range(6*16000))).tobytes(),True),
        ('clear English',wav_pcm(build/'qwen-short-fixture.wav'),False)]
    if args.problem_audio:cases.append(('recorded problem excerpt',wav_pcm(args.problem_audio),False))
    for index,(name,data,silent) in enumerate(cases):
        result=run(python,model,worker,data,terms,build/f'no-speech-{index}.log')
        passed=result['normal_exit'] and result['stopped'] and result['error_events']==0 and result['prompt_echo_events']==0
        if silent:passed=passed and result['result_events']==0
        if name=='clear English':passed=passed and 'mutex' in result['final_text'].lower() and 'critical section' in result['final_text'].lower()
        reports.append({'name':name,'passed':passed,'private_audio':name=='recorded problem excerpt',
            **{k:v for k,v in result.items() if k!='final_text'}})
        print(('PASS' if passed else 'FAIL')+': '+name+'; emitted events='+str(result['result_events']),flush=True)
    report={'microphone_used':False,'private_audio_content_published':False,'all_passed':all(x['passed'] for x in reports),'cases':reports}
    (build/'qwen-no-speech-regression.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['all_passed']:raise SystemExit(1)
