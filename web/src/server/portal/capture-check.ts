// r47: a capture that "failed" because another request was capturing the same PaymentIntent (Stripe: "There is currently
// another in-progress request using this Idempotent Key") is not a failure: the other request (the webhook, or the
// browser's own settle) is finishing it. The booking was marked unpaid and an urgent capture_failed To do opened while the
// money was in fact taken (CC-10139, CC-10468). Now the intent is read again a few times, waiting between reads, before
// anything is recorded; only a capture Stripe really refused (or one still not captured after the waits) is a failure.
// No imports: unit tested in Node (capture-check.test.ts).

/** Stripe's answer when the same idempotency key is in flight in another request. */
export const IDEMPOTENCY_CLASH = /another in-progress request using this idempotent key|idempotency.*in progress|request_in_progress/i;

export type CaptureCheck = 'captured' | 'failed';
export type IntentLike = { status: string } | null;

/** Waits (ms) between the reads of the intent after a failed capture: a clash gets longer, a refusal one quick read. */
export function recheckDelays(errorMessage: string): number[] {
  return IDEMPOTENCY_CLASH.test(errorMessage) ? [800, 1600, 3200, 5000] : [0];
}

/** Read the intent again after a failed capture until it shows captured, or the waits run out. */
export async function recheckCapture(errorMessage: string, read: () => Promise<IntentLike>, sleep: (ms: number) => Promise<void>): Promise<CaptureCheck> {
  for (const ms of recheckDelays(errorMessage)) {
    if (ms) await sleep(ms);
    const now = await read().catch(() => null);
    if (now?.status === 'succeeded') return 'captured';
    // refused for good: no wait changes it
    if (now && now.status !== 'requires_capture' && now.status !== 'processing') return 'failed';
  }
  return 'failed';
}
