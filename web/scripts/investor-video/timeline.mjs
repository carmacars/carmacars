// The investor video, step 3: the timeline (docs/investor-video/script.md).
//   node scripts/investor-video/timeline.mjs --dir <out> [--estimate]
// Reads <dir>/plan.json and <dir>/voice/durations.json (tts.mjs; --estimate: from the word count, for a preview) and
// writes <dir>/timeline.json (every slide's moment on screen, its transition, where each voice line and whoosh goes) and
// <dir>/captions.vtt (the script's words, timed to the voice).
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { report } from './report.mjs';

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const dir = resolve(arg('dir', '.video'));
const plan = JSON.parse(readFileSync(join(dir, 'plan.json'), 'utf8'));
const durFile = join(dir, 'voice/durations.json');
const estimate = process.argv.includes('--estimate') || !existsSync(durFile);
const voice = estimate ? plan.scenes.map((s) => s.words / 2.8) : JSON.parse(readFileSync(durFile, 'utf8')).scenes.map((s) => s.seconds);

export const FPS = 30;
const TIN = 0.7;        // a transition between scenes
const TIN_G = 0.45;     // a transition between the slides of a feature group
const LEAD = 0.6;       // from the start of a scene to its first word
const TAIL = 0.85;      // from the last word to the end of the scene
const MIN_SCENE = 3.4;
const INTRO = 2.6;      // a feature group's opening slide
const FEATURE = 1.2;    // each feature slide, at least
const KINDS = ['fade', 'slide', 'zoom'];

const beats = [], scenes = [], voices = [], whooshes = [];
let t = 0;
plan.scenes.forEach((s, i) => {
  const v = voice[i];
  const start = i === 0 ? 0 : t;
  const kin = i === 0 ? 'fade' : KINDS[i % KINDS.length];
  const nF = s.slides.length - 1;
  const need = LEAD + v + TAIL;
  const D = nF ? Math.max(need, INTRO + nF * FEATURE) : Math.max(need, MIN_SCENE);
  if (nF) {
    const f = D / (INTRO + nF * FEATURE);
    beats.push({ slide: s.slides[0], start, tin: TIN, kin, speed: 1, scene: i });
    for (let k = 1; k <= nF; k++) {
      const len = FEATURE * f;
      beats.push({ slide: s.slides[k], start: start + INTRO * f + (k - 1) * len, tin: TIN_G, kin: 'push', speed: Math.min(1, len / 2.4), scene: i });
      whooshes.push({ t: +(start + INTRO * f + (k - 1) * len - 0.1).toFixed(3), gain: 0.35 });
    }
  } else beats.push({ slide: s.slides[0], start, tin: TIN, kin, speed: 1, scene: i });
  if (i > 0) whooshes.push({ t: +(start - 0.2).toFixed(3), gain: 1 });
  scenes.push({ n: s.n, title: s.title, start: +start.toFixed(3), dur: +D.toFixed(3) });
  voices.push({ n: s.n, at: +(start + LEAD).toFixed(3), seconds: +v.toFixed(3) });
  t = start + D - TIN;
});
const total = +(t + TIN + 0.4).toFixed(3);
beats.forEach((b, k) => { const n = beats[k + 1]; b.end = +(n ? n.start + n.tin : total).toFixed(3); b.start = +b.start.toFixed(3); });

// captions: each sentence (long ones split at a comma, colon or semicolon), timed by its share of the scene's characters
const cues = [];
plan.scenes.forEach((s, i) => {
  const chunks = [];
  for (const sent of s.text.split(/(?<=[.!?])\s+/)) {
    if (sent.length <= 90) { chunks.push(sent); continue; }
    let cur = '';
    for (const part of sent.split(/(?<=[,:;])\s+/)) {
      if (cur && (cur + ' ' + part).length > 90) { chunks.push(cur); cur = part; } else cur = cur ? `${cur} ${part}` : part;
    }
    if (cur) chunks.push(cur);
  }
  const chars = chunks.reduce((a, c) => a + c.length, 0);
  let at = voices[i].at;
  for (const c of chunks) {
    const d = (voices[i].seconds * c.length) / chars;
    cues.push({ from: at, to: at + d, text: c });
    at += d;
  }
});
const ts = (x) => { const ms = Math.round(x * 1000); const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60; return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}.${String(ms % 1000).padStart(3, '0')}`; };
const vtt = ['WEBVTT', '', ...cues.flatMap((c, k) => [String(k + 1), `${ts(c.from)} --> ${ts(Math.max(c.to, c.from + 0.8))}`, c.text, ''])].join('\n');

writeFileSync(join(dir, 'timeline.json'), JSON.stringify({ fps: FPS, width: 1920, height: 1080, total, frames: Math.ceil(total * FPS), estimate, scenes, beats, voices, whooshes }, null, 2));
writeFileSync(join(dir, 'captions.vtt'), vtt);
report('notice', 'timeline', `${scenes.length} scenes, ${beats.length} slides on screen, ${total.toFixed(1)} s (${Math.floor(total / 60)}:${String(Math.round(total % 60)).padStart(2, '0')})${estimate ? ', voice estimated from the words' : ''}`);
