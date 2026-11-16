import type { SlotPhoto } from './types.ts';
import { SLOT_CARS, type SlotCarBox } from './slot-cars-data.ts';

// Release 48 O (3080). The owner (Nov 15): the decorative sections and the home hero (not the listings or the car cards)
// show a real fleet car as a background-removed cutout at the exact angle, size and position of the sample car of the
// section photo, over the section's own background (no dealership background), the hero rotating through real cars.
//   * The section photo must still be the stand-in that has the sample car (its file name); the plate is that photo
//     without the car (scripts/slot-plates.mjs), the boxes are where the sample car stood (src/lib/slot-cars-data.ts).
//   * The cutouts (app.site_cutouts: side profiles, made once by the local cut-out step and kept in Storage) stand in those
//     boxes: as long as the sample car, on the same ground line, centred on it; mirrored when the nose points the other way.
//   * Nothing matches (a section photo replaced in Site content, or no cutout yet): null, and the section shows its photo
//     as before (the sample stays).
// Pure (unit tested); the page reads the cutouts once when it is built.
export interface SiteCutout { vehicle_id: string; path: string; width: number; height: number; facing: 'left' | 'right'; alt?: string | null }
export interface SceneCar { path: string; width: number; height: number; mirror: boolean; alt: string }
export interface SceneFrame { width: number; height: number; plate: string; boxes: SlotCarBox[] }
/** One section: the wide frame (48rem and up) and the tall frame, and for each position the cars it shows (in turn when
 *  more than one: the hero). */
export interface SlotScene { slot: string; wide: SceneFrame; tall: SceneFrame; cars: SceneCar[][] }

/** The most cars the hero shows in turn. */
export const HERO_MAX = 6;
const base = (p: string) => p.split('/').pop() ?? '';

/** The section photo is still the stand-in of this slot (site/<slot>-wide.svg and -tall.svg). */
export function isStandIn(slot: string, p: SlotPhoto | null): boolean {
  if (!p) return false;
  const b = slot.replace('.', '-');
  return base(p.wide.path) === `${b}-wide.svg` && base(p.tall.path) === `${b}-tall.svg`;
}

/** The scene of one section, or null when the section keeps its photo. `rotate`: the one position shows every car in turn
 *  (the hero); otherwise each position shows one car, the sections starting at different cars. */
export function slotScene(slot: string, p: SlotPhoto | null, cutouts: readonly SiteCutout[], { rotate = false }: { rotate?: boolean } = {}): SlotScene | null {
  const place = SLOT_CARS[slot];
  if (!place || !p || !isStandIn(slot, p)) return null;
  const pool = cutouts.filter((c) => c.path && c.width > 0 && c.height > 0);
  if (!pool.length) return null;
  const b = slot.replace('.', '-');
  const car = (c: SiteCutout): SceneCar => ({ path: c.path, width: c.width, height: c.height, mirror: c.facing !== place.facing, alt: c.alt ?? '' });
  const n = place.wide.length;
  const k = [...slot].reduce((a, ch) => (a * 31 + ch.charCodeAt(0)) >>> 0, 7) % pool.length;
  const cars = rotate
    ? [pool.slice(0, HERO_MAX).map(car)]
    : Array.from({ length: n }, (_, i) => [car(pool[(k + i) % pool.length]!)]);
  return {
    slot, cars,
    wide: { width: p.wide.width, height: p.wide.height, plate: `/site-plates/${b}-wide-plate.svg`, boxes: place.wide },
    tall: { width: p.tall.width, height: p.tall.height, plate: `/site-plates/${b}-tall-plate.svg`, boxes: place.tall }
  };
}

/** Where a car stands in its box, in percent of the frame: as long as the sample car, its wheels on the sample's ground
 *  line, centred on the sample car. */
export function carPlace(box: SlotCarBox): { left: number; width: number; bottom: number } {
  const r = (v: number) => Math.round(v * 100) / 100;
  return { left: r(box.left), width: r(box.width), bottom: r(100 - box.top - box.height) };
}
