import type { CarRow, Photo } from './types.ts';

// Release 48 (3040). The owner (Nov 15): "on the CarmaCars homepage and stuff, wherever there's a sample photo, we're going
// to be rotating through real photos in all of the exact same angles as the sample photo so that it looks really clean."
// The studio covers of real cars (app.site_studio_covers: photo standard r48.2, the front three-quarter with the nose to the
// left, as the sample covers; only covers that passed the check) are matched to each slot that showed a sample photo:
//   * an example car's card (a sample car): real cars of the same body style, else of the same class;
//   * a real car's card that has no photo of its own yet: only real cars of the same make and model;
//   (the home hero: r48 O, 3080, shows real cars cut out instead, lib/slot-cars.ts)
// No match: the sample photo stays. Pure (unit tested); the page reads the covers once when it is built.
export interface StudioCover { vehicle_id: string; path: string; variants?: Photo['variants']; width?: number; height?: number; alt?: string | null }
/** The most covers a card shows in turn. */
export const STUDIO_MAX = 4;

const norm = (s: string | null | undefined) => (s ?? '').trim().toLowerCase();

/** The real covers for one card whose photo is a sample photo (none for a card with its own photo). */
export function studioPool(c: CarRow, covers: readonly StudioCover[], byId: ReadonlyMap<string, CarRow>, max = STUDIO_MAX): Photo[] {
  if (!c.cover?.sample) return [];
  const real = covers.filter((x) => x.vehicle_id !== c.vehicle_id && byId.has(x.vehicle_id));
  const car = (x: StudioCover) => byId.get(x.vehicle_id)!;
  let pick: StudioCover[];
  if (!c.is_sample) {
    pick = real.filter((x) => norm(car(x).make) === norm(c.make) && norm(car(x).model) === norm(c.model));
  } else {
    const body = norm(c.body_style);
    pick = body ? real.filter((x) => norm(car(x).body_style) === body) : [];
    if (!pick.length) pick = real.filter((x) => car(x).class === c.class || car(x).classes?.some((k) => c.classes?.includes(k)));
  }
  if (!pick.length) return [];
  // each card starts at another car, so the cards of a grid do not all show the same car
  const k = [...c.slug].reduce((a, ch) => (a * 31 + ch.charCodeAt(0)) >>> 0, 7) % pick.length;
  return [...pick.slice(k), ...pick.slice(0, k)].slice(0, max).map((x) => ({
    path: x.path, variants: x.variants ?? null, width: x.width ?? 1800, height: x.height ?? 1200,
    alt: `${[c.year, c.make, c.model].filter(Boolean).join(' ')}: a photo of a similar car of our fleet`
  }));
}

/** The cars with `studio` filled where their photo is a sample photo; the rows themselves are not changed. `fleet`: the
 *  real cars the covers belong to (the site's fleet read). */
export function withStudio<T extends CarRow>(rows: readonly T[], covers: readonly StudioCover[], fleet: readonly CarRow[] = rows): T[] {
  if (!covers.length) return [...rows];
  const byId = new Map(fleet.filter((x) => !x.is_sample).map((x) => [x.vehicle_id, x] as const));
  return rows.map((c) => { const studio = studioPool(c, covers, byId); return studio.length ? { ...c, studio } : c; });
}

/** The cross-fade of a card's covers: 5 seconds a photo, a 1-second fade, in CSS (no script). */
export const CARD_STEP = 5, CARD_FADE = 1;
export function cardKeyframes(n: number): string {
  if (n < 2) return '';
  const cycle = n * CARD_STEP;
  const pct = (s: number) => `${((s / cycle) * 100).toFixed(3)}%`;
  return `@keyframes card-studio-${n}{0%{opacity:0}${pct(CARD_FADE)}{opacity:1}${pct(CARD_STEP)}{opacity:1}${pct(CARD_STEP + CARD_FADE)}{opacity:0}100%{opacity:0}}`;
}
