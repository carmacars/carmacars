// The nightly "unlinked Stripe payments" check (r35, migration 1081): Stripe's succeeded charges of the last 60 days, as
// the database keeps them (public.server_stripe_unlinked_save decides which are tied to nothing and guesses the booking).
// Only what finds a booking travels: amount, currency, time, the payer's email and name, the card brand and last 4 and the
// booking number a payment link kept; never a card number. No imports: unit tested in Node.
export const UNLINKED_DAYS = 60;

export interface ChargeIn { id: string; intentId: string | null; amountCents: number; refundedCents: number; currency: string; created: number; status: string;
  captured: boolean; email: string | null; name: string | null; last4: string | null; brand: string | null; description: string | null; metadata: Record<string, string> }
export interface ChargeRow { id: string; intent_id: string | null; amount_cents: number; refunded_cents: number; currency: string; created: number; email: string | null;
  name: string | null; last4: string | null; brand: string | null; description: string | null; booking_number: string | null }

/** The time the check reads from: 60 days back, in seconds since 1970. */
export const unlinkedSince = (now = Date.now()) => Math.floor(now / 1000) - UNLINKED_DAYS * 86_400;

/** The charges to send: succeeded and captured (a hold is not money yet), each once. */
export function chargeRows(charges: ChargeIn[]): ChargeRow[] {
  const seen = new Set<string>();
  const out: ChargeRow[] = [];
  for (const c of charges) {
    if (c.status !== 'succeeded' || !c.captured || seen.has(c.id) || !(c.amountCents > 0)) continue;
    seen.add(c.id);
    const bn = c.metadata?.booking_number ?? c.metadata?.booking ?? null;
    out.push({ id: c.id, intent_id: c.intentId, amount_cents: c.amountCents, refunded_cents: c.refundedCents || 0, currency: (c.currency || 'cad').toLowerCase(), created: c.created,
      email: c.email ? c.email.trim().toLowerCase().slice(0, 200) : null, name: c.name ? c.name.trim().slice(0, 120) : null, last4: c.last4 && /^\d{4}$/.test(c.last4) ? c.last4 : null,
      brand: c.brand ?? null, description: c.description ? c.description.slice(0, 200) : null, booking_number: typeof bn === 'string' && bn.trim() ? bn.trim().toUpperCase().slice(0, 40) : null });
  }
  return out;
}
