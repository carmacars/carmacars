// R50 hotfix 2 (migration 5080): standard r48.4, the studio composite. The keyed car (studio-gate.ts chromaKey) is framed to
// its own edges with its contact shadow (subject-frame.ts frameRgba), placed at its view's target (STUDIO_FRAME: the same
// size and place for every car), and drawn on the dealership room the site draws itself (showroom.ts: the CarmaCars sign on
// the wall, the polished floor with the car's reflection). The owner's spec (5080): every background is identical across
// all photos and all cars, so the room carries no car name and is never redrawn by Gemini. Pure: unit tested in
// studio-gate.test.ts.
import { ROOM, composeShowroom, showroomBackdrop } from './showroom.ts';
import { frameRgba, placeSubject, type Rgba } from './subject-frame.ts';
import { EXTRA_FRAME, STUDIO_FRAME, STUDIO_MAX_HEIGHT, type FBox } from './studio-gate.ts';

/** The place of a view: its target's width and tyre line, the height cap. */
export function fitFor(shot: string): { carWidth: number; carHeight: number; floor: number } {
  const t = STUDIO_FRAME[shot] ?? EXTRA_FRAME;
  return { carWidth: t.width, carHeight: STUDIO_MAX_HEIGHT, floor: 1 - t.bottom };
}

export interface Composite {
  /** the finished view, ROOM size (1800 x 1200), opaque */
  img: Rgba;
  /** the same room without the car: one identical image for every car (the drive-off matte's plate) */
  backdrop: Rgba;
  /** the car alone at its place in the frame, the rest transparent (the cutout of the cards and the drive-off's matte) */
  layer: Rgba;
  /** the car's box in the frame (fractions) */
  car: FBox;
}

/** The keyed car (`cut`: RGBA, the background transparent, ROOM size or any size) on the dealership at its view's place. null
 *  when no car could be framed. */
export function composeStudio(cut: Rgba, shot: string): Composite | null {
  const f = frameRgba(cut);
  if (!f) return null;
  const W = ROOM.width, H = ROOM.height;
  const place = placeSubject(f, W, H, fitFor(shot));
  const top = H - place.bottom - place.height;
  const backdrop = showroomBackdrop();
  const img = composeShowroom({ ...f.image, ground: f.ground }, place, {}, backdrop);
  const carW = place.width * (1 - 2 * f.side), carH = place.height * (1 - f.ground);
  return { img, backdrop, layer: carLayer(f.image, place.left, top, place.width, place.height, W, H),
    car: { x: (place.left + place.width * f.side) / W, y: top / H, w: carW / W, h: carH / H } };
}

/** `car` scaled (bilinear, premultiplied) into the box (left, top, w, h) of a transparent W x H frame. */
export function carLayer(car: Rgba, left: number, top: number, w: number, h: number, W: number, H: number): Rgba {
  const out = new Uint8ClampedArray(W * H * 4);
  const sx = car.width / w, sy = car.height / h, d = car.data;
  const x0 = Math.max(0, Math.floor(left)), x1 = Math.min(W, Math.ceil(left + w)), y0 = Math.max(0, Math.floor(top)), y1 = Math.min(H, Math.ceil(top + h));
  for (let y = y0; y < y1; y++) {
    const fy = Math.min(car.height - 1, Math.max(0, (y - top + 0.5) * sy - 0.5)), iy = Math.floor(fy), ty = fy - iy, iy2 = Math.min(car.height - 1, iy + 1);
    for (let x = x0; x < x1; x++) {
      const fx = Math.min(car.width - 1, Math.max(0, (x - left + 0.5) * sx - 0.5)), ix = Math.floor(fx), tx = fx - ix, ix2 = Math.min(car.width - 1, ix + 1);
      let a = 0, r = 0, g = 0, b = 0;
      for (const [px, py, wt] of [[ix, iy, (1 - tx) * (1 - ty)], [ix2, iy, tx * (1 - ty)], [ix, iy2, (1 - tx) * ty], [ix2, iy2, tx * ty]] as const) {
        const i = (py * car.width + px) * 4, al = (d[i + 3]! / 255) * wt;
        a += al; r += d[i]! * al; g += d[i + 1]! * al; b += d[i + 2]! * al;
      }
      if (a <= 0) continue;
      const o = (y * W + x) * 4;
      out[o] = r / a; out[o + 1] = g / a; out[o + 2] = b / a; out[o + 3] = a * 255;
    }
  }
  return { width: W, height: H, data: out };
}

/** The part of `img` inside `box` (fractions): the side profile's cutout for the home sections (cropped to the car). */
export function cropBox(img: Rgba, box: FBox): Rgba {
  const x0 = Math.max(0, Math.floor(box.x * img.width)), y0 = Math.max(0, Math.floor(box.y * img.height));
  const w = Math.max(1, Math.min(img.width - x0, Math.ceil(box.w * img.width))), h = Math.max(1, Math.min(img.height - y0, Math.ceil(box.h * img.height)));
  const out = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) out.set(img.data.subarray(((y0 + y) * img.width + x0) * 4, ((y0 + y) * img.width + x0 + w) * 4), y * w * 4);
  return { width: w, height: h, data: out };
}
