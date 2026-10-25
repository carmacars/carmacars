// The investor video, step 2: the voice (docs/investor-video/script.md).
//   CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... node scripts/investor-video/tts.mjs --dir <out>
// Speaks each scene's narration with Cloudflare Workers AI text to speech (REST: /accounts/<id>/ai/run/<model>), one
// clip per scene, trimmed of leading and trailing silence and saved as 48 kHz mono WAV in <out>/voice/NN.wav, with
// <out>/voice/durations.json. Deepgram Aura 2 first (the most natural voice); Aura 1, then MeloTTS, only if it fails.
// The first model that speaks scene 1 speaks every scene, so the voice never changes mid-video.
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { report } from './report.mjs';

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const dir = resolve(arg('dir', '.video'));
const { CLOUDFLARE_ACCOUNT_ID: acc, CLOUDFLARE_API_TOKEN: token } = process.env;
if (!acc || !token) { console.error('CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN are needed'); process.exit(1); }
const plan = JSON.parse(readFileSync(join(dir, 'plan.json'), 'utf8'));
const vdir = join(dir, 'voice');
mkdirSync(vdir, { recursive: true });

const gh = (level, msg) => report(level, 'tts', msg);
const SPEAKER = process.env.TTS_SPEAKER || 'thalia';
const MODELS = [
  { model: '@cf/deepgram/aura-2-en', body: (text) => ({ text, speaker: SPEAKER, encoding: 'mp3' }) },
  { model: '@cf/deepgram/aura-1', body: (text) => ({ text, speaker: 'asteria', encoding: 'mp3' }) },
  { model: '@cf/myshell-ai/melotts', body: (text) => ({ prompt: text, lang: 'en' }) }
];

async function speak(m, text) {
  for (let attempt = 1; ; attempt++) {
    const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acc}/ai/run/${m.model}`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(m.body(text))
    });
    const type = r.headers.get('content-type') || '';
    if (r.ok && type.startsWith('audio/')) return Buffer.from(await r.arrayBuffer());
    const body = await r.text();
    if (r.ok) {
      // some models answer JSON with the audio in base64
      try { const j = JSON.parse(body); const a = j.result?.audio ?? j.audio; if (a) return Buffer.from(a, 'base64'); } catch { /* not JSON */ }
    }
    if (attempt >= 3 || (r.status >= 400 && r.status < 500 && r.status !== 429)) throw new Error(`${m.model}: ${r.status} ${type} ${body.slice(0, 300)}`);
    await new Promise((ok) => setTimeout(ok, 2000 * attempt));
  }
}

const ff = (args) => { const p = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args]); if (p.status !== 0) throw new Error(String(p.stderr)); };
const seconds = (f) => Number(spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).stdout.toString().trim());

let chosen = null;
const out = [];
for (const s of plan.scenes) {
  let audio;
  if (!chosen) {
    for (const m of MODELS) {
      try { audio = await speak(m, s.say); chosen = m; break; } catch (e) { gh('warning', `tts: ${e.message}`); }
    }
    if (!chosen) { gh('error', 'tts: no model spoke'); process.exit(1); }
    gh('notice', `tts: ${chosen.model}${chosen.model.includes('aura-2') ? ` (${SPEAKER})` : ''}`);
  } else audio = await speak(chosen, s.say);
  const rawf = join(vdir, `${String(s.n).padStart(2, '0')}.raw`);
  const wav = join(vdir, `${String(s.n).padStart(2, '0')}.wav`);
  writeFileSync(rawf, audio);
  // trim silence at both ends (the timeline sets the pauses), 48 kHz mono
  ff(['-i', rawf, '-af', 'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.08,areverse,aresample=48000', '-ac', '1', '-c:a', 'pcm_s16le', wav]);
  const sec = seconds(wav);
  out.push({ n: s.n, title: s.title, seconds: sec, words: s.words });
  console.log(`tts: ${String(s.n).padStart(2, '0')} ${sec.toFixed(2)} s  ${s.title}`);
}
writeFileSync(join(vdir, 'durations.json'), JSON.stringify({ model: chosen.model, speaker: chosen.model.includes('aura-2') ? SPEAKER : null, scenes: out }, null, 2));
gh('notice', `tts: ${out.reduce((a, x) => a + x.seconds, 0).toFixed(1)} s of voice`);
