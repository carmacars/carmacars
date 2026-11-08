// The suggested angles of a check-in, a check-out and a pickup from or return to an owner (migration 0545): guidance,
// never one upload per angle. A photo tagged with an angle ticks it; the uploader may tick one by hand. Pure: the photo
// picker, the database (app.angle_shot maps each to the report's shot) and the unit test share the keys.
export const ANGLES: ReadonlyArray<readonly [string, string]> = [
  ['front', 'Front'], ['front_left', 'Front left'], ['left', 'Left'], ['rear_left', 'Rear left'], ['rear', 'Rear'], ['rear_right', 'Rear right'],
  ['right', 'Right'], ['front_right', 'Front right'], ['odometer', 'Odometer'], ['fuel', 'Fuel gauge'], ['interior_front', 'Interior front'],
  ['interior_rear', 'Interior rear'], ['trunk', 'Trunk'], ['wheels', 'Wheels'], ['damage', 'Any damage']
];
export const ANGLE_KEYS = new Set(ANGLES.map(([k]) => k));
export const angleLabel = (k: string | null | undefined) => ANGLES.find(([x]) => x === k)?.[1] ?? 'Other';

export interface PickedPhoto { bucket: string; path: string; angle: string | null; name: string }

/** The angles covered: tagged on a photo, or ticked by hand. */
export function anglesDone(photos: ReadonlyArray<Pick<PickedPhoto, 'angle'>>, ticked: ReadonlySet<string> = new Set()): Set<string> {
  const out = new Set(ticked);
  for (const p of photos) if (p.angle && ANGLE_KEYS.has(p.angle)) out.add(p.angle);
  return out;
}

/** Where an uploaded photo is kept, by what it is for (the database accepts only these shapes). */
export type PhotoScope = 'return-claim' | 'self-pickup' | 'one-screen' | 'owner-handoff';
export function photoKey(scope: PhotoScope, id: string, uuid: string, png: boolean): string {
  return `${scope === 'owner-handoff' ? 'vehicles' : 'bookings'}/${id}/${scope}/${uuid}.${png ? 'png' : 'jpg'}`;
}
