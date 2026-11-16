// Release 48 O (3080): the cutouts' storage keys and limits (server/site-cutouts.ts). Pure, for the unit test.
export interface CutoutDue { vehicle_id: string; shot: 'left' | 'front_left'; name?: string; source: { kind: 'studio' | 'listing' | 'handover' | 'stock'; bucket: string; path: string; facing: 'left' | 'right' } }
/** The widest cutout kept (the hero's car is drawn at most about 1000 CSS pixels wide on a 2x screen at 1440). */
export const CUTOUT_MAX_WIDTH = 1600;
/** vehicle-public/site/cutouts/<car>/<shot>-<hash>.webp: a new cutout gets a new name (no stale copy at the edge). */
export function cutoutKey(vehicle: string, shot: string, sha1: string): string {
  if (!/^[0-9a-f-]{36}$/i.test(vehicle)) throw new Error('not a car id');
  if (!/^[a-z_]{2,20}$/.test(shot)) throw new Error('not a shot');
  return `site/cutouts/${vehicle.toLowerCase()}/${shot}-${sha1.slice(0, 12)}.webp`;
}
