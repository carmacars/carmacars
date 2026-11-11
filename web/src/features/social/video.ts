// Release 36b (2210): the 9:16 short video of a car, made in the browser. Each photo shows for a few seconds with a slow
// zoom and pan (ken burns), the next fading in; the brand sits at the top and the car, the price and the call to action
// at the bottom. Drawn on a canvas and recorded with MediaRecorder from the canvas stream (MP4 where the browser records
// it, WebM otherwise): free, nothing leaves the browser until the finished file is saved. The maths here is pure (tested).

export const VIDEO_W = 720;
export const VIDEO_H = 1280;
export const FPS = 30;
export const FADE_S = 0.6;
/** Bits a second: about 3.5 MB for 10 seconds, so a video of 8 photos stays well under the 14 MB upload. */
export const BITRATE = 2_800_000;
export const MAX_BYTES = 14 * 1024 * 1024;

export interface Frame { sx: number; sy: number; sw: number; sh: number }

/** The part of a photo shown at t (0..1) of its time: covering the 9:16 frame, zooming from 1.0 to 1.12 (or out on every
 *  other photo) and drifting across the spare width, so no two photos move the same way. */
export function kenBurns(imgW: number, imgH: number, t: number, index: number, outW = VIDEO_W, outH = VIDEO_H): Frame {
  const p = Math.min(1, Math.max(0, t));
  const ease = p * p * (3 - 2 * p);
  const zoomIn = index % 2 === 0;
  const z = zoomIn ? 1 + 0.12 * ease : 1.12 - 0.12 * ease;
  const aspect = outW / outH;
  // the largest window of the frame's shape inside the photo, then made smaller by the zoom
  let bw = imgW, bh = imgW / aspect;
  if (bh > imgH) { bh = imgH; bw = imgH * aspect; }
  const sw = bw / z, sh = bh / z;
  const dir = index % 3 === 0 ? 1 : index % 3 === 1 ? -1 : 0;
  const spareX = imgW - sw, spareY = imgH - sh;
  const fx = dir === 0 ? 0.5 : dir > 0 ? 0.2 + 0.6 * ease : 0.8 - 0.6 * ease;
  return { sx: spareX * fx, sy: spareY * 0.5, sw, sh };
}

/** Which photo (and how far into it) shows at a time, and the fade of the next one. */
export function slideAt(time: number, count: number, per: number): { index: number; t: number; next: number | null; mix: number } {
  if (count <= 0) return { index: 0, t: 0, next: null, mix: 0 };
  const index = Math.min(count - 1, Math.floor(time / per));
  const into = time - index * per;
  const fadeFrom = per - FADE_S;
  const next = index + 1 < count && into > fadeFrom ? index + 1 : null;
  return { index, t: into / per, next, mix: next === null ? 0 : (into - fadeFrom) / FADE_S };
}

export const videoSeconds = (count: number, per: number) => Math.round(count * per * 10) / 10;

/** The recording type the browser supports: MP4 first (posts everywhere as is), WebM otherwise. */
export function pickMime(isSupported: (t: string) => boolean): { mime: string; type: 'video/mp4' | 'video/webm'; ext: 'mp4' | 'webm' } | null {
  for (const m of ['video/mp4;codecs=avc1.42E01F', 'video/mp4;codecs=avc1', 'video/mp4']) if (isSupported(m)) return { mime: m, type: 'video/mp4', ext: 'mp4' };
  for (const m of ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm']) if (isSupported(m)) return { mime: m, type: 'video/webm', ext: 'webm' };
  return null;
}

/** Breaks a line of text into lines that fit a width (measure: the canvas' measureText). */
export function wrap(text: string, width: number, measure: (s: string) => number, maxLines = 2): string[] {
  const words = text.split(/\s+/).filter(Boolean);
  const out: string[] = [];
  let line = '';
  for (const w of words) {
    const next = line ? `${line} ${w}` : w;
    if (measure(next) <= width || !line) line = next;
    else { out.push(line); line = w; }
  }
  if (line) out.push(line);
  if (out.length > maxLines) { const kept = out.slice(0, maxLines); kept[maxLines - 1] = `${kept[maxLines - 1]}…`; return kept; }
  return out;
}

export interface VideoKit { name: string; price: string | null; cta: string; brand: string; seconds_per_photo: number }

/** Draws one frame: the photos, a dark fade top and bottom for the words, the brand, the car and the call to action. */
export function drawFrame(ctx: CanvasRenderingContext2D, imgs: CanvasImageSource[], sizes: Array<{ w: number; h: number }>, kit: VideoKit, time: number): void {
  const per = Number(kit.seconds_per_photo) || 2.5;
  const s = slideAt(time, imgs.length, per);
  ctx.fillStyle = '#0B0B0C';
  ctx.fillRect(0, 0, VIDEO_W, VIDEO_H);
  const paint = (i: number, t: number, alpha: number) => {
    const img = imgs[i], size = sizes[i];
    if (!img || !size) return;
    const f = kenBurns(size.w, size.h, t, i);
    ctx.globalAlpha = alpha;
    ctx.drawImage(img, f.sx, f.sy, f.sw, f.sh, 0, 0, VIDEO_W, VIDEO_H);
    ctx.globalAlpha = 1;
  };
  paint(s.index, s.t, 1);
  if (s.next !== null) paint(s.next, 0, s.mix);
  const top = ctx.createLinearGradient(0, 0, 0, 220);
  top.addColorStop(0, 'rgba(0,0,0,0.65)'); top.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.fillStyle = top; ctx.fillRect(0, 0, VIDEO_W, 220);
  const bottom = ctx.createLinearGradient(0, VIDEO_H - 460, 0, VIDEO_H);
  bottom.addColorStop(0, 'rgba(0,0,0,0)'); bottom.addColorStop(1, 'rgba(0,0,0,0.85)');
  ctx.fillStyle = bottom; ctx.fillRect(0, VIDEO_H - 460, VIDEO_W, 460);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'alphabetic';
  ctx.fillStyle = '#FFFFFF';
  ctx.font = '800 46px system-ui, -apple-system, "Segoe UI", sans-serif';
  ctx.fillText(kit.brand, VIDEO_W / 2, 110);
  ctx.fillStyle = '#E10600';
  ctx.fillRect(VIDEO_W / 2 - 40, 132, 80, 6);
  ctx.fillStyle = '#FFFFFF';
  ctx.font = '700 52px system-ui, -apple-system, "Segoe UI", sans-serif';
  const nameLines = wrap(kit.name, VIDEO_W - 96, (x) => ctx.measureText(x).width);
  let y = VIDEO_H - 250 - (nameLines.length - 1) * 60;
  for (const l of nameLines) { ctx.fillText(l, VIDEO_W / 2, y); y += 60; }
  ctx.font = '600 36px system-ui, -apple-system, "Segoe UI", sans-serif';
  for (const l of wrap(kit.cta, VIDEO_W - 96, (x) => ctx.measureText(x).width)) { ctx.fillText(l, VIDEO_W / 2, y + 30); y += 46; }
}
