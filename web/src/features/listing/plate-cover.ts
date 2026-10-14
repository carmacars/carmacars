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
