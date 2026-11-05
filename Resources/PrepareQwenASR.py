"""Prepare a private, portable Qwen-ASR runtime; inference is a separate offline process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

MODEL_REPO = 'mlx-community/Qwen3-ASR-1.7B-4bit'
MODEL_REVISION = '78a389c776a5483b2d0d4ea5494e11012e0d6159'
MODEL_SHA256 = '9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45'
MODEL_FILES = ['config.json', 'model.safetensors', 'model.safetensors.index.json',
               'tokenizer_config.json', 'chat_template.json', 'generation_config.json',
               'merges.txt', 'vocab.json', 'preprocessor_config.json', 'README.md', 'LICENSE', 'LICENSE.txt']
child = None

def emit(message, progress):
    print(json.dumps({'kind': 'status', 'message': message, 'progress': progress}, ensure_ascii=False), flush=True)

def cancelled(signum, frame):
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
    raise SystemExit(130)

def main():
    global child
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--model-source')
    parser.add_argument('--reuse-dependencies', action='store_true')
    args = parser.parse_args()
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, cancelled)
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    if not args.reuse_dependencies:
        emit('正在安装千问识别运行组件', 0.15)
        env = os.environ.copy()
        # Model download occurs only during explicit preparation, never inference.
        for key in ['HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE']:
            env.pop(key, None)
        requirements = Path(__file__).with_name('qwen-asr-requirements.txt')
        child = subprocess.Popen([sys.executable, '-I', '-m', 'pip', 'install', '--disable-pip-version-check',
            '--only-binary=:all:', '--index-url', 'https://pypi.org/simple', '-r', str(requirements)],
            stdout=sys.stderr, stderr=sys.stderr, env=env, start_new_session=True)
        if child.wait() != 0:
            raise RuntimeError('运行组件安装失败，请检查网络后重试。')
        child = None
    emit('正在准备语音识别模型（约 1.6GB）', 0.4)
    model = root / 'model'
    model.mkdir(exist_ok=True)
    if args.model_source:
        source = Path(args.model_source).resolve()
        for name in MODEL_FILES:
            if (source / name).is_file() and (source / name).resolve() != (model / name).resolve():
                shutil.copy2(source / name, model / name)
    else:
        os.environ.pop('HF_HUB_OFFLINE', None)
        os.environ.pop('TRANSFORMERS_OFFLINE', None)
        from huggingface_hub import snapshot_download
        snapshot_download(MODEL_REPO, revision=MODEL_REVISION, local_dir=str(model), allow_patterns=MODEL_FILES)
    required = ['model.safetensors', 'config.json', 'tokenizer_config.json', 'preprocessor_config.json']
    if any(not (model / name).is_file() for name in required):
        raise RuntimeError('模型文件不完整，未标记为就绪。')
    config = json.loads((model / 'config.json').read_text())
    if config.get('model_type') != 'qwen3_asr' or config.get('auto_map'):
        raise RuntimeError('所选文件不是受支持的本机 Qwen3-ASR 模型。')
    emit('正在校验识别组件和模型', 0.9)
    import mlx.core as mx
    import mlx_audio
    import transformers
    if not mx.metal.is_available():
        raise RuntimeError('当前运行环境未提供 Apple GPU 加速。')
    digest = hashlib.sha256()
    with (model / 'model.safetensors').open('rb') as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != MODEL_SHA256:
        raise RuntimeError('模型校验失败，未标记为就绪。请重新准备。')
    report = {'model_repo': MODEL_REPO, 'revision': MODEL_REVISION, 'weights_sha256': digest.hexdigest(),
              'transformers': transformers.__version__, 'python': sys.version.split()[0], 'ready': True}
    temporary = root / 'ready.json.tmp'
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(root / 'ready.json')
    emit('千问识别已就绪 · 音频在本机处理', 1)
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'kind': 'error', 'message': str(error)[:500]}, ensure_ascii=False), flush=True)
        raise SystemExit(1)
