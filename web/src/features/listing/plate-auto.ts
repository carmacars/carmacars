import { normalizePlateBoxes, type PlateBox } from '../tolls/vision-schema.ts';
import { clampBox, refineBox, type Grey, type NBox } from './plate-cover.ts';
import type { PxBox } from './plate-photo.ts';
import type { Rgba } from './subject-frame.ts';

// Release 41 (migration 2530): the licence plate on every listing photo is checked by itself. The worker asks the vision
// model where the plates are and how sure it is that none can be seen; here, without any I/O, the answer becomes one of
// three decisions: cover the plates found, mark the photo "No plate visible", or leave it for a person. A wrong cover
// is undone with one click; a plate left readable is worse, so a weak box never clears a photo.

export const PLATE_AUTO_SYSTEM = 'You find licence plates in photos of cars for a car rental website. Answer with JSON only, in the shape asked.';
/** The photo's size in pixels is given, so the model answers in pixels (0042: its fractions were placed too low). */
export function plateAutoPrompt(size: { width: number; height: number }): string {
  return `This photo is ${Math.round(size.width)} pixels wide and ${Math.round(size.height)} pixels high. Find every licence plate (number plate) in it: the front or rear plate of any car, also a plate seen at an angle, small, partly hidden or in a reflection. Answer with one JSON object: {"plates": [{"x1": 0, "y1": 0, "x2": 0, "y2": 0, "confidence": 0}], "plate_visible": "yes", "confidence": 0}. Each entry of "plates" is one plate: x1 and y1 the pixel position of its top left corner, x2 and y2 of its bottom right corner (x from the left edge, y from the top edge), confidence 0 to 100. "plate_visible" is "yes" when any plate can be seen, "no" when you are sure none can be seen (an interior, a dashboard, a seat, a trunk, a wheel, a close-up without a plate), "unsure" otherwise; the outer "confidence" (0 to 100) is how sure you are of "plate_visible". Answer {"plates": [], "plate_visible": "no", "confidence": 95} only when no plate can be seen.`;
}
/** r44: the same question in Gemini's own box format (box_2d, y first, on a 0 to 1000 grid), which it places far better than
 *  pixel corners; normalizePlateBoxes reads both. */
export const PLATE_AUTO_PROMPT_GEMINI = 'Find every licence plate (number plate) in this photo: the front or rear plate of any car, also one seen at an angle, small or partly hidden. A sign, a logo or lettering on a wall, a badge or a model name on the car is not a plate. Answer with one JSON object: {"plates": [{"box_2d": [ymin, xmin, ymax, xmax], "confidence": 0}], "plate_visible": "yes", "confidence": 0}. box_2d is the plate\'s box on a 0 to 1000 grid of the image (y first), confidence 0 to 100. "plate_visible" is "yes" when any plate can be seen, "no" when you are sure none can be seen, "unsure" otherwise; the outer "confidence" is how sure you are of "plate_visible". Answer {"plates": [], "plate_visible": "no", "confidence": 95} only when no plate can be seen.';
/** r44: where a plate can be on an outside photo of one car: on the car's bumper, so in the lower part of the frame and not
 *  wider than a plate can be. A box higher up or wider is a sign, the CarmaCars logo or the model's name on the showroom wall
 *  (the owner saw the plate drawn there: "the plate text placed somewhere random"), and is never covered. */
export const PLATE_ZONE = { minCentreY: 0.42, maxWidth: 0.24 } as const;
export const onCarPlate = (b: NBox) => b.y + b.h / 2 >= PLATE_ZONE.minCentreY && b.w <= PLATE_ZONE.maxWidth;
export const PLATE_AUTO_SCHEMA = {
  type: 'object',
  properties: {
    plates: { type: 'array', items: { type: 'object', properties: { x1: { type: 'number' }, y1: { type: 'number' }, x2: { type: 'number' }, y2: { type: 'number' }, confidence: { type: ['number', 'null'] } } } },
    plate_visible: { type: 'string' }, confidence: { type: ['number', 'null'] }
  },
  required: ['plates']
} as const;

export type PlateDecision = 'cover' | 'no_plate' | 'unsure';
export interface Decided { decision: PlateDecision; confidence: number | null; boxes: PlateBox[]; why: string }
export const COVER_MIN = 55, CLEAR_MIN = 85;
/** A box below this is not trusted to cover, but is enough to stop a photo being cleared. */
export const WEAK_MIN = 30;

const pct = (n: unknown): number | null => (typeof n === 'number' && Number.isFinite(n) ? Math.max(0, Math.min(100, n <= 1 && n > 0 ? n * 100 : n)) : typeof n === 'string' && /^\d+(\.\d+)?$/.test(n) ? pct(Number(n)) : null);

/** Intersection over union of two boxes (fractions). */
export function iou(a: NBox, b: NBox): number {
  const x0 = Math.max(a.x, b.x), y0 = Math.max(a.y, b.y), x1 = Math.min(a.x + a.w, b.x + b.w), y1 = Math.min(a.y + a.h, b.y + b.h);
  const i = Math.max(0, x1 - x0) * Math.max(0, y1 - y0);
  const u = a.w * a.h + b.w * b.h - i;
  return u > 0 ? i / u : 0;
}
/** The same plate answered twice (a model repeats itself): the surer box kept. */
export function dedupeBoxes<T extends NBox & { confidence: number }>(boxes: T[], over = 0.4): T[] {
  const out: T[] = [];
  for (const b of [...boxes].sort((p, q) => q.confidence - p.confidence)) if (!out.some((o) => iou(o, b) > over)) out.push(b);
  return out;
}

/**
 * The model's answer as a decision. inside: an inside or detail shot (dashboard, seats, trunk, odometer, detail), where a plate
 * is rare: no plate unless the model sees one.
 */
export function decidePlate(answer: unknown, o: { width: number; height: number; inside: boolean; coverMin?: number; clearMin?: number }): Decided {
  const coverMin = o.coverMin ?? COVER_MIN, clearMin = o.clearMin ?? CLEAR_MIN;
  const a = (answer && typeof answer === 'object' ? answer : null) as Record<string, unknown> | null;
  if (!a || !(Array.isArray(a.plates) || Array.isArray(a.boxes))) return { decision: 'unsure', confidence: null, boxes: [], why: 'no usable answer' };
  const all = dedupeBoxes(normalizePlateBoxes(a, { width: o.width, height: o.height }));
  // r44: on an outside photo only a box where a plate can be (onCarPlate) is covered; one elsewhere is never drawn on, but
  // it still stops the photo being cleared by itself (a person looks)
  const boxes = o.inside ? all : all.filter(onCarPlate);
  const offCar = all.filter((b) => !boxes.includes(b) && b.confidence >= WEAK_MIN);
  const strong = boxes.filter((b) => b.confidence >= coverMin);
  if (strong.length) {
    // every plate the model is fairly sure of is covered, the weaker ones with it (a cover where none was is undone by a person)
    const cover = boxes.filter((b) => b.confidence >= WEAK_MIN);
    return { decision: 'cover', confidence: Math.round(Math.max(...strong.map((b) => b.confidence))), boxes: cover, why: `${cover.length} plate${cover.length === 1 ? '' : 's'} found` };
  }
  if (boxes.some((b) => b.confidence >= WEAK_MIN)) return { decision: 'unsure', confidence: Math.round(Math.max(...boxes.map((b) => b.confidence))), boxes, why: 'a possible plate' };
  if (offCar.length) return { decision: 'unsure', confidence: Math.round(Math.max(...offCar.map((b) => b.confidence))), boxes: [], why: 'a box where no plate can be (a sign or lettering?)' };
  const visible = typeof a.plate_visible === 'string' ? a.plate_visible.toLowerCase() : null;
  const sure = pct(a.confidence);
  if (visible === 'yes') return { decision: 'unsure', confidence: sure, boxes: [], why: 'a plate seen but not placed' };
  if (o.inside) return { decision: 'no_plate', confidence: sure ?? clearMin, boxes: [], why: 'inside or detail shot, no plate seen' };
  if (visible === 'no' && sure !== null && sure >= clearMin) return { decision: 'no_plate', confidence: sure, boxes: [], why: 'no plate visible' };
  return { decision: 'unsure', confidence: sure, boxes: [], why: 'not sure' };
}

/** A box (fractions) in pixels of an image W by H, at least 2 pixels each way, as the cover draws it (plate-cover.ts px). */
export function toPx(b: NBox, W: number, H: number): PxBox {
  const c = clampBox(b);
  const x = Math.floor(c.x * W), y = Math.floor(c.y * H);
  return { x, y, w: Math.max(2, Math.min(W - x, Math.ceil(c.w * W))), h: Math.max(2, Math.min(H - y, Math.ceil(c.h * H))) };
}
/** Boxes as the database keeps them (four decimals, inside the photo). */
export const boxesForSave = (boxes: NBox[]) => boxes.map((b) => { const c = clampBox(b); return { x: +c.x.toFixed(4), y: +c.y.toFixed(4), w: +c.w.toFixed(4), h: +c.h.toFixed(4) }; });

/** The photo small and grey (refineBox's input), from decoded pixels (the worker has no canvas). */
export function greyOfRgba(img: Rgba, longSide = 360): Grey {
  const k = Math.min(1, longSide / Math.max(img.width, img.height));
  const w = Math.max(1, Math.round(img.width * k)), h = Math.max(1, Math.round(img.height * k));
  const data = new Uint8ClampedArray(w * h);
  for (let y = 0; y < h; y++) {
    const sy = Math.min(img.height - 1, Math.floor(y / k));
    for (let x = 0; x < w; x++) {
      const i = (sy * img.width + Math.min(img.width - 1, Math.floor(x / k))) * 4;
      data[y * w + x] = (img.data[i]! * 299 + img.data[i + 1]! * 587 + img.data[i + 2]! * 114) / 1000;
    }
  }
  return { width: w, height: h, data };
}
/** The model's rough boxes moved onto the plate's edges when they stand out (as the editor does); never smaller than the plate. */
export function refineAll(g: Grey | null, boxes: NBox[]): NBox[] {
  return boxes.map((b) => {
    if (!g) return clampBox(b);
    const r = refineBox(g, { x: b.x, y: b.y, w: b.w, h: b.h });
    if (!r.moved) return clampBox(b);
    // the refined window is the characters' band: a margin keeps the plate's frame covered
    const m = r.box, mx = m.w * 0.12, my = m.h * 0.2;
    return clampBox({ x: m.x - mx, y: m.y - my, w: m.w + 2 * mx, h: m.h + 2 * my });
  });
}
