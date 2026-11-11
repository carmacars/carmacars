// "I've returned the car" (migration 0532): the renter's short form from the one-tap link in every overdue notice, or the
// button on their booking. Everything is optional; what the renter gives is kept as renter-provided until staff confirm.
// No imports: the page, the upload route and the unit test share it.

/** The fuel gauge as the renter reads it, stored as a percentage like the check-out report. */
export const FUEL_LEVELS: ReadonlyArray<readonly [string, number]> = [
  ['Full', 100], ['3/4', 75], ['1/2', 50], ['1/4', 25], ['Empty', 0]
];

export const MAX_PHOTOS = 30;
export const MAX_PHOTO_BYTES = 8 * 1024 * 1024;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Where one uploaded photo of a booking's report is kept (the database accepts only this shape for the booking). */
export function claimPhotoKey(bookingId: string, id: string, png: boolean): string {
  return `bookings/${bookingId}/return-claim/${id}.${png ? 'png' : 'jpg'}`;
}

export interface ClaimInput { returned_at?: string; odometer_km?: string; fuel_pct?: string; note?: string; photos?: Array<{ bucket: string; path: string; angle?: string | null }> }

/** The form's values as the database's payload, or the first problem in words the renter reads. */
export function claimPayload(v: ClaimInput, now: Date = new Date()): { ok: true; payload: Record<string, unknown> } | { ok: false; message: string } {
  const out: Record<string, unknown> = {};
  if (v.returned_at) {
    const t = new Date(v.returned_at);
    if (Number.isNaN(t.getTime())) return { ok: false, message: 'Enter the date and time you returned the car.' };
    if (t.getTime() > now.getTime() + 5 * 60_000) return { ok: false, message: 'The return time cannot be in the future.' };
    out.returned_at = t.toISOString();
  }
  if (v.odometer_km && v.odometer_km.trim()) {
    const km = Number(v.odometer_km.replace(/[\s,]/g, ''));
    if (!Number.isInteger(km) || km < 0 || km > 2_000_000) return { ok: false, message: 'Enter the odometer in whole kilometres.' };
    out.odometer_km = km;
  }
  if (v.fuel_pct !== undefined && v.fuel_pct !== '') {
    const f = Number(v.fuel_pct);
    if (!FUEL_LEVELS.some(([, p]) => p === f)) return { ok: false, message: 'Pick the fuel level.' };
    out.fuel_pct = f;
  }
  const note = (v.note ?? '').trim();
  if (note) out.note = note.slice(0, 1000);
  const photos = v.photos ?? [];
  if (photos.length > MAX_PHOTOS) return { ok: false, message: `Up to ${MAX_PHOTOS} photos.` };
  out.photos = photos;
  return { ok: true, payload: out };
}

/** What the staff card says of a fuel percentage. */
export function fuelLabel(pct: number | null | undefined): string {
  if (pct === null || pct === undefined) return 'not given';
  return FUEL_LEVELS.find(([, p]) => p === pct)?.[0] ?? `${pct}%`;
}

/** The renter's booking page offers "I've returned the car" (the self checkout) while the car is out (0545). */
export function returnReportable(status: string, returnAt: string, now: Date = new Date()): boolean {
  // 0545: the renter's own checkout, any time while the car is out (it was the late window only)
  void returnAt; void now;
  return status === 'on_rent';
}

/** 0545: the renter's own check-in is offered from 24 hours before the pickup, once the offer is approved. */
// Renters can always check in on their own (hotfix Nov 11): before pickup, at pickup, and after the trip has started
// (their photos then join the pickup report).
export function selfPickupOffered(status: string): boolean {
  return status === 'confirmed' || status === 'pending_payment' || status === 'on_rent';
}
