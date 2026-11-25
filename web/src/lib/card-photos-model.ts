// The car card's photo and drive-off rules (release 50, 5030; src/lib/card-photos.ts). Pure, unit tested.

/** The crossfade between photos under a moving mouse (car-card.css: 180 ms). */
export const SCRUB_FADE_MS = 180;
/** How long the mouse rests on a card before its photo list is read (a pass across the page reads nothing). */
export const INTENT_MS = 60;
/** The drive-off (car-card.css car-drive-*). */
export const DRIVE_MS = 620;
/** A click or tap starts the car page this long after the drive-off starts (the wind-up and the launch are seen; the
 *  owner's limit is about 250 ms). */
export const DRIVE_NAV_MS = 140;
/** Still on the page this long after a drive-off (the navigation was refused or slow): the car comes back. */
export const DRIVE_RESET_MS = 1600;

/** The photo a pointer at x (from the photo's left edge) picks: the photo is cut into n equal segments. */
export function segmentAt(x: number, width: number, n: number): number {
  if (!(width > 0) || n <= 1 || !Number.isFinite(x)) return 0;
  return Math.max(0, Math.min(n - 1, Math.floor((x / width) * n)));
}

/** The photo a swiped track rests on (one photo a snap). */
export function snapIndex(scrollLeft: number, width: number, n: number): number {
  if (!(width > 0) || n <= 1) return 0;
  return Math.max(0, Math.min(n - 1, Math.round(scrollLeft / width)));
}

/** The next photo for an arrow key: no wrap (as the swipe, which stops at the ends). */
export function stepIndex(at: number, key: string, n: number): number | null {
  if (n <= 1) return null;
  if (key === 'ArrowRight') return at < n - 1 ? at + 1 : null;
  if (key === 'ArrowLeft') return at > 0 ? at - 1 : null;
  return null;
}

export interface Box { x: number; y: number; w: number; h: number }
/** The car's box from the card's data-box ("x,y,w,h", fractions); null when it is not one. */
export function parseBox(s: string | null | undefined): Box | null {
  const v = (s ?? '').split(',').map(Number);
  if (v.length !== 4 || v.some((n) => !Number.isFinite(n) || n < 0 || n > 1)) return null;
  const [x, y, w, h] = v as [number, number, number, number];
  return w > 0.1 && h > 0.05 ? { x, y, w, h } : null;
}

/** Where the body pivots as it squats: its rear wheel on the floor (the nose leads, so the rear is the far side). */
export function rearPivot(b: Box, facing: 'left' | 'right'): { x: string; y: string } {
  const x = facing === 'left' ? b.x + b.w * 0.8 : b.x + b.w * 0.2;
  return { x: `${(x * 100).toFixed(1)}%`, y: `${((b.y + b.h) * 100).toFixed(1)}%` };
}

/** Whether a click opens the car with the drive-off: the main button with no modifier (a new tab opens at once). */
export function plainClick(e: { button: number; metaKey: boolean; ctrlKey: boolean; shiftKey: boolean; altKey: boolean }): boolean {
  return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey;
}

/** The photos after the cover for a card of n photos (the gallery's order, the cover and any placeholder left out). */
export function slidePhotos<T extends { path: string; sample?: boolean; placeholder?: boolean }>(list: T[], cover: string | null, n: number): T[] {
  return list.filter((p) => p && typeof p.path === 'string' && !p.sample && !p.placeholder && p.path !== cover).slice(0, Math.max(0, n - 1));
}
