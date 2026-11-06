// Listing photos in any order (release 28, B8; migration 0566): which shot a photo is, as the vision model sees it, and
// where it is filed. Pure, so the upload route and the unit tests share it (photo-sort.test.ts).
//
// The model names one of the shots; a named shot that already has its photo (each takes one) sends the new photo to the
// extra outside photos ("exterior_more", which get the studio) or the extra detail photos ("other", kept as taken), so a
// photo never replaces another by itself. When the model cannot say, the photo goes to the detail photos (never the studio:
// a dashboard on a studio backdrop would be wrong).

export const NAMED_EXTERIOR = ['front_left', 'front', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right'] as const;
export const NAMED_INTERIOR = ['dashboard', 'front_seats', 'rear_seats', 'trunk', 'wheel', 'odometer'] as const;
const NAMED = new Set<string>([...NAMED_EXTERIOR, ...NAMED_INTERIOR]);

export const SORT_SYSTEM = 'You sort photos of a car for a rental listing. Answer with JSON only.';
export const SORT_PROMPT = [
  'Which view of the car is this photo? Choose exactly one "shot":',
  'front_left (front three-quarter from the driver\'s side), front, left (the driver\'s side, flat), rear_left, rear, rear_right, right, front_right,',
  'dashboard (the dashboard and steering wheel), front_seats, rear_seats, trunk, wheel (a close-up of a wheel), odometer (the instrument cluster showing the kilometres),',
  'exterior_other (another outside view: a detail of the body, the roof, the engine bay), interior_other (another inside view: the sunroof, a screen, the third row).',
  'Also say whether the photo has an overlaid watermark, logo or caption text that is not part of the car or the scene (for example another site\'s corner mark, or the words of a model name printed on the photo): "watermark": true or false.',
  'Answer as {"shot": "<one of the codes>", "watermark": <true|false>}.'
].join(' ');

export interface Sorted { shot: string; watermark: boolean; exterior: boolean }

/** The model's answer as a shot (a code, or exterior_other / interior_other), or null when it did not answer usefully. */
export function parseSort(data: unknown): { shot: string; watermark: boolean } | null {
  const d = (data ?? {}) as { shot?: unknown; watermark?: unknown };
  const shot = typeof d.shot === 'string' ? d.shot.trim().toLowerCase().replace(/[\s-]+/g, '_') : '';
  if (!NAMED.has(shot) && shot !== 'exterior_other' && shot !== 'interior_other') return null;
  return { shot, watermark: d.watermark === true || d.watermark === 'true' };
}

/** Where the photo is filed, given the shots that already have a photo on the listing. */
export function fileAs(sorted: { shot: string; watermark: boolean } | null, taken: ReadonlySet<string>): Sorted {
  if (!sorted) return { shot: 'other', watermark: false, exterior: false };
  const exterior = (NAMED_EXTERIOR as readonly string[]).includes(sorted.shot) || sorted.shot === 'exterior_other';
  if (NAMED.has(sorted.shot) && !taken.has(sorted.shot)) return { shot: sorted.shot, watermark: sorted.watermark, exterior };
  return { shot: exterior ? 'exterior_more' : 'other', watermark: sorted.watermark, exterior };
}

// ---------------------------------------------------------------- r28: a mark or caption on an inside or detail photo
// The photo worker asks the vision model where the overlaid marks are (the photo flagged "watermark" by the sorter, or
// queued for the check), then cuts the edge band that holds them off (trim) before the photo is framed again. A mark the
// crop cannot take off without losing too much of the photo (one in the middle) keeps the photo off the site.
export const MARK_SYSTEM = 'You find overlaid marks on photos of cars. Answer with JSON only.';
export const MARK_PROMPT = [
  'Find every overlaid watermark, logo or caption text printed on top of this photo that is not part of the car or the scene',
  '(for example a dealer\'s or another site\'s corner mark, a phone number, or a model name written on the photo).',
  'Do not count badges, screens, labels or text that are physically on the car.',
  'Give each as a box in fractions of the photo\'s width and height (0 to 1): {"marks": [{"x": <left>, "y": <top>, "w": <width>, "h": <height>}]}.',
  'Answer {"marks": []} when there is none.'
].join(' ');

export interface MarkBox { x: number; y: number; w: number; h: number }
/** The model's boxes as fractions (it may answer in fractions, per mille, percent or pixels of the size it saw); null
 *  when the answer is not a list of marks. */
export function parseMarks(data: unknown, size: { width: number; height: number }): MarkBox[] | null {
  const list = (data as { marks?: unknown } | null)?.marks;
  if (!Array.isArray(list)) return null;
  const out: MarkBox[] = [];
  for (const m of list.slice(0, 8)) {
    const o = (m ?? {}) as Record<string, unknown>;
    let [x, y, w, h] = ['x', 'y', 'w', 'h'].map((k) => Number(o[k])) as [number, number, number, number];
    if (![x, y, w, h].every((n) => Number.isFinite(n) && n >= 0) || !(w > 0) || !(h > 0)) continue;
    const top = Math.max(x + w, y + h);
    // fractions as asked; else percent; else pixels of the image the model saw
    const kx = top <= 1.001 ? 1 : top <= 100 ? 100 : size.width, ky = kx === size.width ? size.height : kx;
    x /= kx; w /= kx; y /= ky; h /= ky;
    const b = { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)), w: 0, h: 0 };
    b.w = Math.max(0, Math.min(1 - b.x, w)); b.h = Math.max(0, Math.min(1 - b.y, h));
    if (b.w > 0.003 && b.h > 0.003) out.push(b);
  }
  return out;
}

/** The edges to cut off (fractions of the photo) so no mark is left, the least of the photo lost; null when that would
 *  lose more than maxLoss of the photo (a mark in the middle). A small margin is cut around each mark. */
export function cropAway(marks: MarkBox[], o: { margin?: number; maxLoss?: number } = {}): { top: number; right: number; bottom: number; left: number } | null {
  const margin = o.margin ?? 0.015, maxLoss = o.maxLoss ?? 0.4;
  if (!marks.length) return { top: 0, right: 0, bottom: 0, left: 0 };
  // each mark is taken off by one of four cuts: the top down to its bottom edge, the bottom up to its top edge, the left
  // across to its right edge, or the right across to its left edge
  const cuts = (m: MarkBox) => [
    { top: m.y + m.h + margin, right: 0, bottom: 0, left: 0 }, { top: 0, right: 0, bottom: 1 - m.y + margin, left: 0 },
    { top: 0, right: 0, bottom: 0, left: m.x + m.w + margin }, { top: 0, right: 1 - m.x + margin, bottom: 0, left: 0 }];
  let best: { top: number; right: number; bottom: number; left: number } | null = null, bestKeep = -1;
  const n = Math.min(marks.length, 5);
  const walk = (i: number, acc: { top: number; right: number; bottom: number; left: number }) => {
    if (i === n) {
      const keep = Math.max(0, 1 - acc.left - acc.right) * Math.max(0, 1 - acc.top - acc.bottom);
      if (keep > bestKeep) { bestKeep = keep; best = { ...acc }; }
      return;
    }
    for (const c of cuts(marks[i]!)) walk(i + 1, { top: Math.max(acc.top, c.top), right: Math.max(acc.right, c.right), bottom: Math.max(acc.bottom, c.bottom), left: Math.max(acc.left, c.left) });
  };
  walk(0, { top: 0, right: 0, bottom: 0, left: 0 });
  if (marks.length > n || bestKeep < 1 - maxLoss || !best) return null;
  const r = (v: number) => Math.min(1, Math.max(0, +v.toFixed(4)));
  const b = best as { top: number; right: number; bottom: number; left: number };
  return { top: r(b.top), right: r(b.right), bottom: r(b.bottom), left: r(b.left) };
}
