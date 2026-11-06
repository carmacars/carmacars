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
