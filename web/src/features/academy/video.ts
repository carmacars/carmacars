// Release 37 (2301): an academy lesson as a real video file, made in the browser for free the way the short car videos are
// (src/features/social/video.ts): each scene drawn on a 16:9 canvas with the player's motion (the items arriving one by one),
// its words as captions at the bottom, and recorded with MediaRecorder (MP4 where the browser records it, WebM otherwise).
// The browser's voice cannot be recorded, so the video carries the words as captions. Timeline and layout maths are pure (tested).
import { sceneMs, shotSrc, words, type Scene } from './model.ts';
import { pickMime, wrap } from '../social/video.ts';

export { pickMime };
export const LESSON_W = 1280;
export const LESSON_H = 720;
export const LESSON_FPS = 30;
/** Bits a second: the scenes are mostly still text, so 1.2 Mbit/s stays sharp (a 3 minute lesson is about 27 MB). */
export const LESSON_BITRATE = 1_200_000;
/** The largest file the site keeps (the upload route refuses more). */
export const LESSON_MAX_BYTES = 80 * 1024 * 1024;
/** Each item of a list, step or chat arrives this long after the one before (the player's --i stagger). */
export const STAGGER_S = 0.35;

/** Where each scene starts and how long it lasts, in seconds, at normal speed (the player's captions-only timing). */
export function timeline(scenes: readonly Scene[]): { starts: number[]; durations: number[]; total: number } {
  const durations = scenes.map((s) => sceneMs(s) / 1000);
  const starts: number[] = [];
  let t = 0;
  for (const d of durations) { starts.push(t); t += d; }
  return { starts, durations, total: Math.round(t * 10) / 10 };
}

/** The scene showing at a time and how far into it (seconds). Past the end: the last scene. */
export function sceneAt(tl: { starts: number[]; durations: number[] }, time: number): { index: number; into: number } {
  if (!tl.starts.length) return { index: 0, into: 0 };
  let i = tl.starts.length - 1;
  while (i > 0 && tl.starts[i]! > time) i--;
  return { index: i, into: Math.max(0, time - tl.starts[i]!) };
}

/** How visible the item n of a scene is at `into` seconds (0..1): each fades in over 0.4 s after its stagger. */
export const itemAlpha = (n: number, into: number) => Math.min(1, Math.max(0, (into - 0.2 - n * STAGGER_S) / 0.4));

const C = { bg: '#0F1B2D', panel: '#17263D', ink: '#F5F7FA', muted: '#A9B4C4', ok: '#2E9E6A', warn: '#D9822B', you: '#2D6CDF', them: '#2A3A55', bar: '#2D6CDF' };
const FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';

/** 2990: the guide screenshots a lesson shows (their addresses), to load before it is recorded. */
export const lessonImages = (scenes: readonly Scene[]): string[] => [...new Set(scenes.flatMap((s) => {
  const v = s.visual;
  if (v.kind === 'shot' && v.img) return [shotSrc(v.img)];
  if (v.kind === 'pic') return [v.src];
  if (v.kind === 'compare') return [v.good.src, v.bad.src]; // 4200: the pictures of the See it lesson
  return [];
}))];

/** 2990: a picture fitted inside a box, keeping its shape, at the box's top left. */
export function fitBox(w: number, h: number, boxW: number, boxH: number): { w: number; h: number } {
  if (!(w > 0 && h > 0)) return { w: 0, h: 0 };
  const k = Math.min(boxW / w, boxH / h);
  return { w: Math.round(w * k), h: Math.round(h * k) };
}

type Img = CanvasImageSource & { width: number; height: number };
/** Draws the lesson at a time: the title card first (1.5 s), then the scenes, the captions and the progress bar. A shot scene
 *  draws its screenshot from `images` (by address) when it was loaded, else its heading and line only. */
export function drawLesson(ctx: CanvasRenderingContext2D, title: string, scenes: readonly Scene[], tl: ReturnType<typeof timeline>, time: number, images?: ReadonlyMap<string, Img>): void {
  const W = LESSON_W, H = LESSON_H;
  ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, H);
  ctx.textBaseline = 'top';
  const { index, into } = sceneAt(tl, time);
  const scene = scenes[index];
  if (!scene) return;
  const m = (s: string) => ctx.measureText(s).width;
  const text = (s: string, x: number, y: number, size: number, color = C.ink, weight = 400, maxW = W - 2 * x, lines = 3, alpha = 1) => {
    ctx.globalAlpha = alpha; ctx.fillStyle = color; ctx.font = `${weight} ${size}px ${FONT}`;
    const out = wrap(s, maxW, m, lines);
    out.forEach((l, k) => ctx.fillText(l, x, y + k * size * 1.25));
    ctx.globalAlpha = 1;
    return y + out.length * size * 1.25;
  };
  // the lesson's name and the scene's caption (the kicker)
  text(title, 64, 36, 22, C.muted, 600, W - 128, 1);
  let y = text(scene.caption, 64, 80, 30, C.muted, 600, W - 128, 1) + 24;
  const v = scene.visual;
  const fadeIn = Math.min(1, into / 0.35);
  if (v.kind === 'title') {
    y = text(v.heading, 64, 220, 64, C.ink, 700, W - 128, 2, fadeIn) + 16;
    if (v.text) text(v.text, 64, y, 32, C.muted, 400, W - 128, 3, fadeIn);
  } else if (v.kind === 'rule') {
    ctx.globalAlpha = fadeIn; ctx.fillStyle = C.panel; ctx.fillRect(64, y, W - 128, 300);
    ctx.fillStyle = v.tone === 'warn' ? C.warn : C.ok; ctx.fillRect(64, y, 10, 300); ctx.globalAlpha = 1;
    const y2 = text(v.heading, 104, y + 32, 40, C.ink, 700, W - 208, 2, fadeIn) + 12;
    text(v.text, 104, y2, 30, C.ink, 400, W - 208, 4, fadeIn);
  } else if (v.kind === 'list' || v.kind === 'steps') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1) + 20;
    v.items.slice(0, 6).forEach((it, n) => {
      const a = itemAlpha(n, into);
      const mark = v.kind === 'steps' ? `${n + 1}.` : '•';
      text(mark, 72, y, 30, C.bar, 700, 48, 1, a);
      y = text(it, 124, y, 30, C.ink, 400, W - 200, 2, a) + 14;
    });
  } else if (v.kind === 'money') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1) + 24;
    const rows: Array<[string, string, boolean]> = [...v.rows.map(([k, x]) => [k, x, false] as [string, string, boolean]), ...(v.total ? [[v.total[0], v.total[1], true] as [string, string, boolean]] : [])];
    rows.slice(0, 7).forEach(([k, x, total], n) => {
      const a = itemAlpha(n, into);
      ctx.globalAlpha = a; ctx.font = `${total ? 700 : 400} 30px ${FONT}`; ctx.fillStyle = C.ink;
      ctx.fillText(k, 96, y); const w = m(x); ctx.fillText(x, W - 96 - w, y);
      ctx.globalAlpha = a * 0.3; ctx.fillRect(96, y + 44, W - 192, 2); ctx.globalAlpha = 1;
      y += 56;
    });
  } else if (v.kind === 'shot') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1, fadeIn) + 12;
    const img = v.img ? images?.get(shotSrc(v.img)) : undefined;
    const boxH = H - 128 - 56 - y;
    if (img) {
      const f = fitBox(img.width, img.height, W - 128, boxH);
      ctx.globalAlpha = fadeIn; ctx.fillStyle = '#FFFFFF'; ctx.fillRect(64, y, f.w, f.h); ctx.drawImage(img, 64, y, f.w, f.h); ctx.globalAlpha = 1;
      y += f.h + 10;
    }
    text(v.text || 'In the guide', 64, Math.min(y, H - 128 - 40), 24, C.muted, 400, W - 128, 1, fadeIn);
  } else if (v.kind === 'pic') {
    // 4200: a screen or photo, with its legend under it
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1, fadeIn) + 12;
    const img = images?.get(v.src);
    const legend = [...(v.pins ?? []).map((p) => `${p.n}. ${p.label}`), ...(v.text ? [v.text] : [])].join('   ');
    const boxH = H - 128 - 56 - y;
    if (img) {
      const f = fitBox(img.width, img.height, W - 128, boxH);
      ctx.globalAlpha = fadeIn; ctx.fillStyle = '#FFFFFF'; ctx.fillRect(64, y, f.w, f.h); ctx.drawImage(img, 64, y, f.w, f.h);
      ctx.fillStyle = '#C8102E';
      for (const p of v.pins ?? []) { const px = 64 + (f.w * p.x) / 100, py = y + (f.h * p.y) / 100; ctx.beginPath(); ctx.arc(px, py, 13, 0, Math.PI * 2); ctx.fill(); ctx.fillStyle = '#FFFFFF'; ctx.font = `700 16px ${FONT}`; ctx.fillText(String(p.n), px - 5, py - 9); ctx.fillStyle = '#C8102E'; }
      ctx.globalAlpha = 1;
      y += f.h + 10;
    }
    text(legend || v.alt, 64, Math.min(y, H - 128 - 40), 24, C.muted, 400, W - 128, 1, fadeIn);
  } else if (v.kind === 'compare') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1, fadeIn) + 12;
    const boxW = (W - 128 - 32) / 2, boxH = H - 128 - 90 - y;
    ([['Good', v.good, '#2E9E6A'], ['Not good', v.bad, '#D9534F']] as const).forEach(([label, p, color], n) => {
      const x = 64 + n * (boxW + 32);
      const img = images?.get(p.src);
      const f = img ? fitBox(img.width, img.height, boxW, boxH) : { w: 0, h: 0 };
      ctx.globalAlpha = fadeIn;
      if (img) { ctx.drawImage(img, x, y, f.w, f.h); ctx.strokeStyle = color; ctx.lineWidth = 5; ctx.strokeRect(x, y, f.w, f.h); }
      ctx.fillStyle = color; ctx.font = `700 22px ${FONT}`; ctx.fillText(label, x, y + f.h + 8);
      ctx.globalAlpha = 1;
      text(p.text, x, y + f.h + 36, 20, C.muted, 400, boxW, 2, fadeIn);
    });
  } else if (v.kind === 'flow') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1, fadeIn) + 20;
    v.steps.slice(0, 7).forEach((st, n) => {
      const a = itemAlpha(n, into);
      text(`${n + 1}.`, 72, y, 30, C.bar, 700, 48, 1, a);
      y = text(st.label, 124, y, 30, C.ink, 400, W - 200, 2, a) + 12;
    });
  } else if (v.kind === 'dodont') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1, fadeIn) + 16;
    v.pairs.slice(0, 3).forEach((p, n) => {
      const a = itemAlpha(n, into);
      y = text(`Do: ${p.do}`, 72, y, 28, C.ok, 600, W - 144, 2, a) + 6;
      y = text(`Do not: ${p.dont}`, 72, y, 28, C.warn, 600, W - 144, 2, a) + 18;
    });
  } else if (v.kind === 'icons') {
    y = text(v.heading, 64, y, 40, C.ink, 700, W - 128, 1, fadeIn) + 20;
    v.items.slice(0, 6).forEach((it, n) => {
      const a = itemAlpha(n, into);
      text('•', 72, y, 30, C.bar, 700, 48, 1, a);
      y = text(it.text, 124, y, 30, C.ink, 400, W - 200, 2, a) + 14;
    });
  } else if (v.kind === 'chat') {
    v.lines.slice(0, 5).forEach((l, n) => {
      const a = itemAlpha(n, into);
      const you = l.who === 'you';
      ctx.font = `400 26px ${FONT}`;
      const lines = wrap(l.text, 640, m, 3);
      const bw = Math.min(700, Math.max(...lines.map(m)) + 48), bh = lines.length * 33 + 54;
      const x = you ? W - 64 - bw : 64;
      ctx.globalAlpha = a; ctx.fillStyle = you ? C.you : C.them; ctx.fillRect(x, y, bw, bh);
      ctx.fillStyle = C.muted; ctx.font = `600 18px ${FONT}`; ctx.fillText(you ? 'You' : l.who.charAt(0).toUpperCase() + l.who.slice(1), x + 24, y + 12);
      ctx.fillStyle = C.ink; ctx.font = `400 26px ${FONT}`; lines.forEach((s, k) => ctx.fillText(s, x + 24, y + 40 + k * 33));
      ctx.globalAlpha = 1;
      y += bh + 14;
    });
  }
  // the captions: the scene's words, on a band at the bottom
  ctx.fillStyle = 'rgba(0,0,0,0.55)'; ctx.fillRect(0, H - 128, W, 116);
  text(words(scene), 64, H - 116, 26, C.ink, 400, W - 128, 3);
  ctx.fillStyle = C.bar; ctx.fillRect(0, H - 8, W * Math.min(1, time / Math.max(0.1, tl.total)), 8);
}
