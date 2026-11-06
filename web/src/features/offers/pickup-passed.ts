// 0569 (r28 P0): an offer for a pickup time already past is not sent; the composer says so and blocks Send until the
// pickup is moved. The same rule for a reopened offer (staff give new dates) and the renter's ask (a future pickup).
export const PICKUP_PASSED = 'Pickup time has passed: update it';

/** Whether a pickup (an ISO time, or a datetime-local value read in this browser's zone) is at or before now. */
export function pickupPassed(at: string | null | undefined, now: number = Date.now()): boolean {
  if (!at) return false;
  const t = new Date(at).getTime();
  return Number.isFinite(t) && t <= now;
}

/** The renter's "Ask to reopen this offer" (0569): what they see once asked, and the check on the optional new pickup. */
export const ASK_REOPEN_DONE = 'We’ve asked the team to reopen it. We’ll text you.';
export function askPickupError(at: string | null | undefined, now: number = Date.now()): string | null {
  if (!at) return null;
  return Number.isFinite(new Date(at).getTime()) && !pickupPassed(at, now) ? null : 'Choose a pickup time in the future, or leave it empty.';
}
