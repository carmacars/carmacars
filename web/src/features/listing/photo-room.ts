// r39 (2400): the showroom in a real photographed room (owner, Nov 11: "the showroom backgrounds behind the cut-out cars look
// fake"). The car's framed cut-out (subject-frame.ts) is placed in a photo of a dealership or studio interior (licensed
// CC0, public domain or CC BY, fetched once by web/scripts/showroom-photos.mjs; rows in showroom_backgrounds):
//   - about 70% of the frame's width (Program settings listing_showroom_car_width), its wheels on the room's floor line,
//     smaller when the car would be taller than half the frame or reach the ceiling (a front or rear view), centred
//   - a soft shadow under the car and a dark contact shadow under each tyre, a faint reflection in the floor (the room's
//     own strength), the car's light and colour nudged towards the room's (never more than a few percent)
//   - no logo and no lettering on the wall: a sign pasted on a photographed wall does not look real
// A cut-out whose mask is poor (pieces, a wide uncertain edge, a ragged outline: maskQuality below Program settings'
// listing_cutout_min_quality) is never composited: the worker uses the real photo instead.
// Pure: no network, no storage.
import type { Rgba } from './subject-frame.ts';
import type { Place } from './showroom.ts';

/** The room's facts the placement needs: the floor line as a share of the frame's height, the car's share of its width. */
export interface PhotoRoomFit { floor: number; carWidth: number }
/** The highest the car's roof may reach (a share of the frame's height from the top), and the most of the frame's height
 *  the car may take above its wheels (a front or rear view is held by its height, as on a dealer's photo). */
export const PHOTO_TOP_MARGIN = 0.08;
export const PHOTO_MAX_HEIGHT = 0.5;

/** Where the framed car goes in a photographed room of W x H: the car itself (without its side margins) carWidth of the
 *  frame wide, the wheels exactly on the floor line, centred; held below PHOTO_TOP_MARGIN (then smaller, still on the
 *  floor line), and never taller above its wheels than PHOTO_MAX_HEIGHT of the frame. `place.bottom` is from the frame's bottom edge (as placeSubject); it may be below zero when the cut-out's
 *  shadow band reaches past the frame. Pure. */
export function photoPlace(f: { width: number; height: number; ground: number; side: number }, W: number, H: number, fit: PhotoRoomFit): Place & { carShare: number; wheel: number } {
  const floor = Math.min(0.97, Math.max(0.5, fit.floor)), share = Math.min(0.9, Math.max(0.3, fit.carWidth));
  const aspect = f.width / f.height, side = Math.min(0.45, Math.max(0, f.side)), ground = Math.min(0.9, Math.max(0, f.ground));
  const wheel = H * floor;
  let width = (W * share) / (1 - 2 * side);
  // the car's height above the wheels at that width; held under the top margin
  const above = (w: number) => (w / aspect) * (1 - ground);
  const room = Math.min(wheel - H * PHOTO_TOP_MARGIN, H * PHOTO_MAX_HEIGHT);
  if (above(width) > room) width = (room / (1 - ground)) * aspect;
  const height = width / aspect;
  const bottom = H - wheel - height * ground;
  return { width: Math.round(width), height: Math.round(height), left: Math.round((W - width) / 2), bottom: Math.round(bottom),
    carShare: (width * (1 - 2 * side)) / W, wheel };
}

/** The mask's quality, 0 to 1, from the cut-out's alpha: one clean piece (the largest piece's share of the firm pixels, few
 *  loose pieces),
 *  a narrow soft edge (semi-transparent pixels per edge pixel), a smooth outline (edge pixels against the square root of
 *  the area). 0 for an empty mask. Read on a grid of at most 400 columns. Pure. */
export function maskQuality(img: Rgba): { score: number; pieces: number; largest: number; soft: number; rough: number } {
  const step = Math.max(1, Math.floor(img.width / 400));
  const gw = Math.floor(img.width / step), gh = Math.floor(img.height / step);
  const firm = new Uint8Array(gw * gh);
  let nFirm = 0, nSoft = 0;
  for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) {
    const a = img.data[((y * step) * img.width + x * step) * 4 + 3]!;
    if (a >= 128) { firm[y * gw + x] = 1; nFirm++; }
    if (a > 20 && a < 235) nSoft++;
  }
  if (nFirm < 50) return { score: 0, pieces: 0, largest: 0, soft: 0, rough: 0 };
  // pieces (4-neighbour), the largest one's share; the edge pixels (firm with a clear neighbour)
  const seen = new Uint8Array(gw * gh), stack = new Int32Array(gw * gh);
  let pieces = 0, largest = 0, edge = 0;
  for (let i = 0; i < gw * gh; i++) {
    if (!firm[i]) continue;
    const x = i % gw, y = (i - x) / gw;
    if (x === 0 || y === 0 || x === gw - 1 || y === gh - 1 || !firm[i - 1] || !firm[i + 1] || !firm[i - gw] || !firm[i + gw]) edge++;
    if (seen[i]) continue;
    let n = 0, sp = 0; stack[sp++] = i; seen[i] = 1;
    while (sp) {
      const k = stack[--sp]!; n++;
      const kx = k % gw;
      if (kx > 0 && firm[k - 1] && !seen[k - 1]) { seen[k - 1] = 1; stack[sp++] = k - 1; }
      if (kx < gw - 1 && firm[k + 1] && !seen[k + 1]) { seen[k + 1] = 1; stack[sp++] = k + 1; }
      if (k >= gw && firm[k - gw] && !seen[k - gw]) { seen[k - gw] = 1; stack[sp++] = k - gw; }
      if (k + gw < gw * gh && firm[k + gw] && !seen[k + gw]) { seen[k + gw] = 1; stack[sp++] = k + gw; }
    }
    if (n >= 4) pieces++;
    if (n > largest) largest = n;
  }
  const share = largest / nFirm;
  const soft = nSoft / Math.max(1, edge);
  const rough = edge / Math.sqrt(nFirm);
  const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
  // a clean anti-aliased edge has one to three soft pixels per edge pixel; a car's outline about 5 to 8 edge pixels per
  // square root of its area (a 3:1 box is 4.6)
  const qSoft = clamp01(1 - Math.max(0, soft - 3) / 6);
  const qRough = clamp01(1 - Math.max(0, rough - 10) / 10);
  // a few specks are common; many loose pieces mean the segmenter kept parts of the room
  const qShare = clamp01((share - 0.75) / 0.2), qPieces = clamp01(1 - Math.max(0, pieces - 3) / 20);
  const score = Math.round(qShare * qPieces * qSoft * qRough * 100) / 100;
  return { score, pieces, largest: Math.round(share * 1000) / 1000, soft: Math.round(soft * 100) / 100, rough: Math.round(rough * 100) / 100 };
}

/** The car's light and colour nudged towards the room's: the room's mean colour around the floor line against the car's
 *  own (its firm pixels), as a gain per channel within 0.9 to 1.1 for the brightness and 4% for the colour. Pure. */
export function lightMatch(room: Rgba, car: Rgba & { ground?: number }, floor: number): [number, number, number] {
  const mean = (img: Rgba, y0: number, y1: number, firmOnly: boolean) => {
    const s: [number, number, number] = [0, 0, 0]; let n = 0;
    const step = Math.max(1, Math.floor(img.width / 200));
    for (let y = Math.max(0, Math.floor(y0)); y < Math.min(img.height, y1); y += step) for (let x = 0; x < img.width; x += step) {
      const i = (y * img.width + x) * 4;
      if (firmOnly && img.data[i + 3]! < 200) continue;
      s[0] += img.data[i]!; s[1] += img.data[i + 1]!; s[2] += img.data[i + 2]!; n++;
    }
    return n ? s.map((v) => v / n) as [number, number, number] : null;
  };
  const r = mean(room, room.height * (floor - 0.35), room.height * Math.min(1, floor + 0.1), false), c = mean(car, 0, car.height * (1 - (car.ground ?? 0)), true);
  if (!r || !c) return [1, 1, 1];
  const lr = (r[0] + r[1] + r[2]) / 3 || 1, lc = (c[0] + c[1] + c[2]) / 3 || 1;
  // brightness: a fifth of the way to the room's (a dark car stays dark), within 10%
  const e = Math.min(1.1, Math.max(0.9, (lr / lc) ** 0.2));
  return [0, 1, 2].map((k) => Math.round(e * Math.min(1.04, Math.max(0.96, 1 + 0.3 * (r[k]! / lr - 1))) * 1000) / 1000) as [number, number, number];
}
