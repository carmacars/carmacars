// r50 (3900): the small rule of the Book instantly / Request to book choice, shared by the car page and the booking flow. Pure.
export type BookHow = 'request' | 'instant';

/** Why Book instantly is closed, in the renter's words (null: open). The database decides again when the request is sent. */
export function instantWhyNot(p: { canBookNow: boolean; carOk: boolean }): string | null {
  if (!p.canBookNow) return 'For Gold Rewards members with a verified licence and nothing owing.';
  if (!p.carOk) return 'Not for these dates or this car: send a request instead.';
  return null;
}
