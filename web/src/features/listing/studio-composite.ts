// R50 hotfix 2 (migration 5080): standard r48.4, the studio composite. The keyed car (studio-gate.ts chromaKey) is framed to
// its own edges with its contact shadow (subject-frame.ts frameRgba), placed at its view's target (STUDIO_FRAME: the same
// size and place for every car), and drawn on the dealership room the site draws itself (showroom.ts: the CarmaCars sign
// and the car's name on the wall, the polished floor with the car's reflection). The room is never redrawn by Gemini, so
// every view of every car stands on exactly the same background. Pure: unit tested in studio-composite.test.ts.
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
  /** the same room without the car (the drive-off matte's plate) */
  backdrop: Rgba;
  /** the car's box in the frame (fractions) */
  car: FBox;
}

/** The keyed car (`cut`: RGBA, the background transparent, ROOM size or any size) on the dealership at its view's place, with
 *  the car's name on the wall (`model`: lettered as the sample covers). null when no car could be framed. */
export function composeStudio(cut: Rgba, shot: string, model: string | null): Composite | null {
  const f = frameRgba(cut);
  if (!f) return null;
  const W = ROOM.width, H = ROOM.height;
  const place = placeSubject(f, W, H, fitFor(shot));
  const top = H - place.bottom - place.height;
  const backdrop = showroomBackdrop({ model, cover: !!model, carTop: top });
  const img = composeShowroom({ ...f.image, ground: f.ground }, place, { model, cover: !!model }, backdrop);
  const carW = place.width * (1 - 2 * f.side), carH = place.height * (1 - f.ground);
  return { img, backdrop, car: { x: (place.left + place.width * f.side) / W, y: top / H, w: carW / W, h: carH / H } };
}
