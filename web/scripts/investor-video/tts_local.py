"""The investor video's voice when Cloudflare Workers AI cannot speak it (docs/investor-video/script.md).

    python scripts/investor-video/tts_local.py --dir <out> [--voice af_heart]

Kokoro-82M (open weights, Apache 2.0) on the CPU: each scene's spoken text from <out>/plan.json, trimmed of silence
at both ends, as 48 kHz mono WAV in <out>/voice/NN.wav, with <out>/voice/durations.json (the same files tts.mjs
writes). Runs in a job of its own with no secrets.
"""
import argparse
import json
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf
from kokoro import KPipeline

ap = argparse.ArgumentParser()
ap.add_argument('--dir', required=True)
ap.add_argument('--voice', default='af_heart')
a = ap.parse_args()
out = Path(a.dir)
plan = json.loads((out / 'plan.json').read_text())
vdir = out / 'voice'
vdir.mkdir(parents=True, exist_ok=True)
pipe = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')

TRIM = ('silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,areverse,'
        'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.08,areverse,aresample=48000')
scenes = []
for s in plan['scenes']:
    n = f"{s['n']:02d}"
    parts = [np.asarray(audio, dtype=np.float32) for _, _, audio in pipe(s['say'], voice=a.voice, speed=1.0)]
    gap = np.zeros(int(24000 * 0.12), dtype=np.float32)
    joined = np.concatenate([x for p in parts for x in (p, gap)][:-1]) if parts else gap
    raw = vdir / f'{n}.raw.wav'
    sf.write(raw, joined, 24000)
    wav = vdir / f'{n}.wav'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(raw), '-af', TRIM, '-ac', '1', '-c:a', 'pcm_s16le', str(wav)], check=True)
    raw.unlink()
    sec = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(wav)],
                               check=True, capture_output=True, text=True).stdout.strip())
    scenes.append({'n': s['n'], 'title': s['title'], 'seconds': sec, 'words': s['words']})
    print(f"tts: {n} {sec:.2f} s  {s['title']}", flush=True)
(vdir / 'durations.json').write_text(json.dumps({'model': 'kokoro-82m (local)', 'speaker': a.voice, 'scenes': scenes}, indent=2))
total = sum(x['seconds'] for x in scenes)
print(f'::notice title=tts::kokoro-82m ({a.voice}), {total:.1f} s of voice', flush=True)
