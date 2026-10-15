// Covering licence plates on listing photos (migration 0042), in the browser: boxes are fractions of the photo,
// so they hold at any size; each box is covered with a CarmaCars plate, pixelated or blurred, on a canvas. The
// box arithmetic is pure (unit tested); the drawing needs a browser canvas.
export interface NBox { x: number; y: number; w: number; h: number; suggested?: boolean }
export type PlateStyle = 'cover' | 'pixelate' | 'blur';

export const clamp01 = (n: number) => Math.max(0, Math.min(1, n));
/** A box kept inside the photo, at least 1% wide and high. */
export function clampBox(b: NBox): NBox {
  const w = Math.max(0.01, Math.min(1, Math.abs(b.w))), h = Math.max(0.01, Math.min(1, Math.abs(b.h)));
  const x = clamp01(b.w < 0 ? b.x + b.w : b.x), y = clamp01(b.h < 0 ? b.y + b.h : b.y);
  return { x: Math.min(x, 1 - w), y: Math.min(y, 1 - h), w, h, ...(b.suggested ? { suggested: true } : {}) };
}
/** The box from two corners (a drag in either direction). */
export const fromCorners = (a: { x: number; y: number }, b: { x: number; y: number }): NBox => clampBox({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) });
export const inside = (b: NBox, p: { x: number; y: number }) => p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h;
/** Near the lower right corner: resize instead of move. */
export const nearCorner = (b: NBox, p: { x: number; y: number }, tol = 0.03) => Math.abs(p.x - (b.x + b.w)) < tol && Math.abs(p.y - (b.y + b.h)) < tol;
/** Boxes as the database keeps them: four decimals, no flag. */
export const forSave = (boxes: NBox[]) => boxes.map((b) => { const c = clampBox(b); return { x: +c.x.toFixed(4), y: +c.y.toFixed(4), w: +c.w.toFixed(4), h: +c.h.toFixed(4) }; });

type Ctx2D = CanvasRenderingContext2D;
const px = (b: NBox, W: number, H: number) => { const c = clampBox(b); const x = Math.floor(c.x * W), y = Math.floor(c.y * H); return { x, y, w: Math.max(2, Math.ceil(c.w * W)), h: Math.max(2, Math.ceil(c.h * H)) }; };
function scratch(w: number, h: number) { const c = document.createElement('canvas'); c.width = Math.max(1, w); c.height = Math.max(1, h); return c; }

function pixelate(ctx: Ctx2D, r: { x: number; y: number; w: number; h: number }) {
  const block = Math.max(6, Math.round(r.w / 9));
  const s = scratch(Math.ceil(r.w / block), Math.ceil(r.h / block));
  const g = s.getContext('2d')!; g.imageSmoothingEnabled = true;
  g.drawImage(ctx.canvas, r.x, r.y, r.w, r.h, 0, 0, s.width, s.height);
  ctx.save(); ctx.imageSmoothingEnabled = false; ctx.drawImage(s, 0, 0, s.width, s.height, r.x, r.y, r.w, r.h); ctx.restore();
}
function blur(ctx: Ctx2D, r: { x: number; y: number; w: number; h: number }) {
  // shrink hard, grow back smoothly, twice: the characters cannot be read (the canvas filter is missing on some phones)
  for (let i = 0; i < 2; i++) {
    const s = scratch(Math.max(2, Math.round(r.w / 18)), Math.max(2, Math.round(r.h / 18)));
    const g = s.getContext('2d')!; g.imageSmoothingEnabled = true; g.imageSmoothingQuality = 'low';
    g.drawImage(ctx.canvas, r.x, r.y, r.w, r.h, 0, 0, s.width, s.height);
    ctx.save(); ctx.imageSmoothingEnabled = true; ctx.drawImage(s, 0, 0, s.width, s.height, r.x, r.y, r.w, r.h); ctx.restore();
  }
}
function cover(ctx: Ctx2D, r: { x: number; y: number; w: number; h: number }, text: string, font: string) {
  const rad = Math.min(r.w, r.h) * 0.14;
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(r.x + rad, r.y); ctx.arcTo(r.x + r.w, r.y, r.x + r.w, r.y + r.h, rad); ctx.arcTo(r.x + r.w, r.y + r.h, r.x, r.y + r.h, rad);
  ctx.arcTo(r.x, r.y + r.h, r.x, r.y, rad); ctx.arcTo(r.x, r.y, r.x + r.w, r.y, rad); ctx.closePath();
  ctx.fillStyle = '#0a0a0a'; ctx.fill();
  ctx.lineWidth = Math.max(1, r.h * 0.05); ctx.strokeStyle = '#ffffff'; ctx.stroke();
  // the red line under the name, as on the wordmark
  ctx.fillStyle = '#d7141a'; ctx.fillRect(r.x + r.w * 0.2, r.y + r.h * 0.76, r.w * 0.6, Math.max(1, r.h * 0.06));
  let size = Math.max(6, r.h * 0.46);
  ctx.font = `700 ${size}px ${font}`;
  const room = r.w * 0.84;
  const m = ctx.measureText(text).width;
  if (m > room) { size = Math.max(5, (size * room) / m); ctx.font = `700 ${size}px ${font}`; }
  ctx.fillStyle = '#ffffff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(text, r.x + r.w / 2, r.y + r.h * 0.44);
  ctx.restore();
}

/** Draw the photo with every box covered, on a canvas of any size. */
export function paint(ctx: Ctx2D, img: CanvasImageSource, W: number, H: number, boxes: NBox[], style: PlateStyle, text: string, font = 'Inter, Arial, sans-serif') {
  ctx.clearRect(0, 0, W, H);
  ctx.drawImage(img, 0, 0, W, H);
  for (const b of boxes) {
    const r = px(b, W, H);
    if (style === 'pixelate') pixelate(ctx, r); else if (style === 'blur') blur(ctx, r); else cover(ctx, r, text, font);
  }
}

/** The covered photo at its own size (at most 3000 px on the long side) and at each of its smaller widths, as JPEG files. */
export async function exportCovered(img: HTMLImageElement, boxes: NBox[], style: PlateStyle, text: string, widths: number[], font?: string): Promise<{ main: Blob; width: number; height: number; variants: Array<{ width: number; blob: Blob }> }> {
  const nw = img.naturalWidth || 1600, nh = img.naturalHeight || 1067;
  const k = Math.min(1, 3000 / Math.max(nw, nh));
  const W = Math.round(nw * k), H = Math.round(nh * k);
  const c = scratch(W, H);
  paint(c.getContext('2d')!, img, W, H, boxes, style, text, font);
  const blob = (cv: HTMLCanvasElement) => new Promise<Blob>((ok, no) => cv.toBlob((b) => (b ? ok(b) : no(new Error('The photo could not be made'))), 'image/jpeg', 0.9));
  const main = await blob(c);
  const variants: Array<{ width: number; blob: Blob }> = [];
  for (const w of [...new Set(widths)].filter((x) => x > 0 && x < W).sort((a, b) => b - a)) {
    const v = scratch(w, Math.round((H * w) / W));
    const g = v.getContext('2d')!; g.imageSmoothingQuality = 'high'; g.drawImage(c, 0, 0, v.width, v.height);
    variants.push({ width: w, blob: await blob(v) });
  }
  return { main, width: W, height: H, variants };
}

/** A grey image: one byte per pixel, row by row. */
export interface Grey { width: number; height: number; data: Uint8ClampedArray | Uint8Array }
/** The photo drawn small and grey, for refineBox (in the browser). */
export function greyOf(img: CanvasImageSource, width: number, height: number, longSide = 360): Grey {
  const k = Math.min(1, longSide / Math.max(width, height));
  const c = scratch(Math.round(width * k), Math.round(height * k));
  const g = c.getContext('2d')!; g.drawImage(img, 0, 0, c.width, c.height);
  const rgba = g.getImageData(0, 0, c.width, c.height).data;
  const data = new Uint8ClampedArray(c.width * c.height);
  for (let i = 0; i < data.length; i++) data[i] = (rgba[i * 4]! * 299 + rgba[i * 4 + 1]! * 587 + rgba[i * 4 + 2]! * 114) / 1000;
  return { width: c.width, height: c.height, data };
}

/**
 * The vision model finds roughly where a plate is (in live tests its box was across the plate but too high or too low).
 * A plate is the place in a photo with the densest vertical edges (its characters) inside a band of light background.
 * Near the model's box, windows of plate shapes are scored by the edges inside them against the edges around them; the
 * best one is taken when it clearly stands out, otherwise the model's box stays. Staff check the box either way.
 */
export function refineBox(g: Grey, guess: NBox): { box: NBox; moved: boolean; score: number } {
  const W = g.width, H = g.height;
  if (W < 16 || H < 16) return { box: guess, moved: false, score: 0 };
  // vertical edges: the absolute horizontal gradient, as an integral image
  const I = new Float64Array((W + 1) * (H + 1));
  for (let y = 0; y < H; y++) {
    let row = 0;
    for (let x = 0; x < W; x++) {
      const i = y * W + x;
      const e = x > 0 && x < W - 1 ? Math.abs(g.data[i + 1]! - g.data[i - 1]!) : 0;
      row += e > 24 ? e : 0;
      I[(y + 1) * (W + 1) + x + 1] = I[y * (W + 1) + x + 1]! + row;
    }
  }
  const sum = (x0: number, y0: number, x1: number, y1: number) => {
    x0 = Math.max(0, Math.min(W, x0)); x1 = Math.max(0, Math.min(W, x1)); y0 = Math.max(0, Math.min(H, y0)); y1 = Math.max(0, Math.min(H, y1));
    return I[y1 * (W + 1) + x1]! - I[y0 * (W + 1) + x1]! - I[y1 * (W + 1) + x0]! + I[y0 * (W + 1) + x0]!;
  };
  const score = (x: number, y: number, w: number, h: number) => {
    const inner = sum(x, y, x + w, y + h) / Math.max(1, w * h);
    const mx = Math.round(w * 0.5), my = Math.round(h * 0.8);
    const outerArea = (w + 2 * mx) * (h + 2 * my) - w * h;
    const outer = (sum(x - mx, y - my, x + w + mx, y + h + my) - sum(x, y, x + w, y + h)) / Math.max(1, outerArea);
    return inner - outer;
  };
  const gw = Math.max(6, guess.w * W), gh = Math.max(3, guess.h * H);
  const cx = (guess.x + guess.w / 2) * W, cy = (guess.y + guess.h / 2) * H;
  const base = score(Math.round(cx - gw / 2), Math.round(cy - gh / 2), Math.round(gw), Math.round(gh));
  let best = { s: base, x: cx - gw / 2, y: cy - gh / 2, w: gw, h: gh };
  const step = Math.max(1, Math.round(Math.min(gw, gh) / 6));
  for (const kw of [0.75, 1, 1.3]) {
    for (const ratio of [2, 2.8, 3.6, 4.5]) {
      const w = Math.round(gw * kw), h = Math.max(3, Math.round(w / ratio));
      const rx = Math.round(Math.max(gw, w) * 1.2), ry = Math.round(Math.max(gh, h) * 2 + H * 0.12);
      for (let y = Math.round(cy - h / 2 - ry); y <= cy - h / 2 + ry; y += step) {
        if (y < 0 || y + h > H) continue;
        for (let x = Math.round(cx - w / 2 - rx); x <= cx - w / 2 + rx; x += step) {
          if (x < 0 || x + w > W) continue;
          // a small pull towards the model's centre, so two equal places choose the nearer one
          const d = Math.hypot((x + w / 2 - cx) / W, (y + h / 2 - cy) / H);
          const s = score(x, y, w, h) * (1 - Math.min(0.3, d));
          if (s > best.s) best = { s, x, y, w, h };
        }
      }
    }
  }
  const moved = best.s > Math.max(4, base * 1.25) && (best.x !== cx - gw / 2 || best.y !== cy - gh / 2);
  if (!moved) return { box: guess, moved: false, score: base };
  return { box: clampBox({ x: best.x / W, y: best.y / H, w: best.w / W, h: best.h / H, suggested: true }), moved: true, score: best.s };
}
