// The investor video, step 5: the sound (docs/investor-video/script.md).
//   node scripts/investor-video/audio.mjs --dir <out>
// Lays each scene's voice (tts.mjs) where the timeline puts it, under it a soft ambient pad synthesized here (sine
// partials of two slow alternating chords, filtered and echoed: no recorded or copyrighted music) ducked whenever the
// voice speaks, and a filtered-noise whoosh at each transition (quieter between the slides of a feature group).
// Loudness normalized to -16 LUFS. Writes <out>/mix.wav (48 kHz stereo).
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const dir = resolve(arg('dir', '.video'));
const tl = JSON.parse(readFileSync(join(dir, 'timeline.json'), 'utf8'));
const T = tl.total.toFixed(3);
const ff = (args) => { const p = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { maxBuffer: 1 << 26 }); if (p.status !== 0) { console.error(String(p.stderr)); process.exit(1); } };

// the pad: A minor 9 and F major 7, crossfading over 24 s, each partial doubled a few cents sharp for width
const chordA = [110, 164.81, 196, 246.94, 261.63];
const chordF = [87.31, 130.81, 164.81, 220, 261.63];
const part = (f) => `(sin(2*PI*${f}*t)+sin(2*PI*${(f * 1.0035).toFixed(3)}*t))`;
const w = '(0.5+0.5*sin(2*PI*t/24))';
const pad = `0.035*(${w}*(${chordA.map(part).join('+')})+(1-${w})*(${chordF.map(part).join('+')}))*(0.85+0.15*sin(2*PI*t/7))`;
ff(['-f', 'lavfi', '-i', `aevalsrc=exprs='${pad}':s=48000:d=${T}`, '-af',
  `lowpass=f=1100,aecho=0.8:0.6:180|360:0.25|0.15,afade=t=in:d=3,afade=t=out:st=${(tl.total - 4).toFixed(3)}:d=4`, '-ac', '1', join(dir, 'pad.wav')]);
// the whoosh: pink noise, band-limited, swelling in and falling away
ff(['-f', 'lavfi', '-i', 'anoisesrc=d=0.9:c=pink:a=0.6:r=48000:s=7', '-af',
  'highpass=f=350,lowpass=f=3200,afade=t=in:d=0.45:curve=exp,afade=t=out:st=0.45:d=0.45:curve=exp,volume=0.5', join(dir, 'whoosh.wav')]);

// the voice track
const vin = tl.voices.flatMap((v) => ['-i', join(dir, 'voice', `${String(v.n).padStart(2, '0')}.wav`)]);
const vchain = tl.voices.map((v, k) => `[${k}:a]adelay=${Math.round(v.at * 1000)}:all=1[v${k}]`).join(';');
ff([...vin, '-filter_complex', `${vchain};${tl.voices.map((_, k) => `[v${k}]`).join('')}amix=inputs=${tl.voices.length}:normalize=0,apad=whole_dur=${T}[out]`,
  '-map', '[out]', '-t', T, '-ac', '1', '-ar', '48000', join(dir, 'voice.wav')]);
// the whooshes track
const n = tl.whooshes.length;
const wchain = `[0:a]asplit=${n}${tl.whooshes.map((_, k) => `[s${k}]`).join('')};` +
  tl.whooshes.map((x, k) => `[s${k}]volume=${x.gain},adelay=${Math.max(0, Math.round(x.t * 1000))}:all=1[w${k}]`).join(';') +
  `;${tl.whooshes.map((_, k) => `[w${k}]`).join('')}amix=inputs=${n}:normalize=0,apad=whole_dur=${T}[out]`;
ff(['-i', join(dir, 'whoosh.wav'), '-filter_complex', wchain, '-map', '[out]', '-t', T, '-ac', '1', join(dir, 'whooshes.wav')]);

// the mix: the pad ducked under the voice, the whooshes low, then -16 LUFS
ff(['-i', join(dir, 'voice.wav'), '-i', join(dir, 'pad.wav'), '-i', join(dir, 'whooshes.wav'), '-filter_complex',
  '[0:a]asplit=2[v][sc];[1:a][sc]sidechaincompress=threshold=0.02:ratio=10:attack=30:release=600:makeup=1[pad];' +
  '[2:a]volume=0.22[wh];[v][pad][wh]amix=inputs=3:normalize=0:weights=1 0.9 1,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[out]',
  '-map', '[out]', '-ac', '2', '-t', T, join(dir, 'mix.wav')]);
console.log(`audio: ${tl.voices.length} voice lines, ${n} whooshes, ${T} s -> ${join(dir, 'mix.wav')}`);
