import 'server-only';
import { rpc } from '@/lib/db/repo';
import { rentalcoverConfigured, rentalcoverQuote } from '@/integrations/rentalcover';

// RentalCover quotes (migration 1202), asked on the server only: the database gives the facts (the car's value check, the
// renter's name, email and age at pickup, a quote still fresh for the same renter and dates), the partner API is asked
// when there is none, and the answer (or the failure, for the log) is recorded. The id of a usable quote goes with the
// checkout quote, the offer or the review screen's save, and the database prices the Protection Plan from it. Anything
// that goes wrong returns null: the plan keeps its current price (the table, or what staff typed).
const SR = { role: 'service_role' as const };

type Facts = { ok: boolean; missing?: string; cached?: { id: string } | null; from_date: string; to_date: string; customer_age: number;
  first_name: string; last_name: string; email: string; country: string; destination_country: string } & Record<string, unknown>;

export type CoverSource = 'checkout' | 'offer' | 'review' | 'request';

/** The id of a RentalCover quote for these facts (p: coverage_option, vehicle_id, pickup_at, return_at, and booking with
 *  changes, renter_id or renter {full_name, email, date_of_birth}), or null. */
export async function rentalcoverQuoteId(p: Record<string, unknown>, source: CoverSource): Promise<string | null> {
  try {
    const facts = (await rpc('server_rentalcover_facts' as never, { p } as never, SR)) as unknown as Facts | null;
    if (!facts?.ok) return null;
    if (facts.cached?.id) return facts.cached.id;
    if (!rentalcoverConfigured()) return null;
    const r = await rentalcoverQuote({ fromDate: facts.from_date, toDate: facts.to_date, customerAge: facts.customer_age, firstName: facts.first_name,
      lastName: facts.last_name, email: facts.email, country: facts.country, destinationCountry: facts.destination_country });
    // the record keeps no name or email (the cache key is a hash of them)
    const rest = Object.fromEntries(Object.entries(facts).filter(([k]) => !['email', 'first_name', 'last_name'].includes(k)));
    const rec = (await rpc('server_rentalcover_record' as never, { p: { ...rest, source, status: r.ok ? 'ok' : 'failed',
      ...(r.ok ? { reference: r.reference, policy_code: r.policyCode, quote_cents: r.totalCents, currency: r.currency, response: r.raw } : { error: r.error }) } } as never, SR)) as unknown as { id: string | null } | null;
    // the failure is in rentalcover_quotes (status failed); the log line names no person
    if (!r.ok) console.warn(`rentalcover: quote failed (${r.error}); the Protection Plan keeps its current price`);
    return rec?.id ?? null;
  } catch (e) {
    console.warn(`rentalcover: quote not available (${e instanceof Error ? e.message.slice(0, 120) : 'error'})`);
    return null;
  }
}

/** An offer or a review-screen payload with the quote's id added when it is for the Protection Plan and no plan price was
 *  typed (a price staff type wins). Never throws. */
export async function withRentalCover(p: Record<string, unknown>, source: CoverSource): Promise<Record<string, unknown>> {
  const typed = typeof p.line_overrides === 'object' && p.line_overrides !== null && 'coverage_sold' in (p.line_overrides as Record<string, unknown>);
  if (typed || p.rentalcover_quote_id) return p;
  const facts: Record<string, unknown> = p.booking
    ? { booking: p.booking, changes: p.changes ?? {}, ...(p.coverage_option !== undefined ? { coverage_option: p.coverage_option } : {}) }
    : { coverage_option: p.coverage_option, vehicle_id: p.vehicle_id, pickup_at: p.pickup_at, return_at: p.return_at, renter_id: p.renter_id ?? null, renter: p.renter ?? null };
  if (!p.booking && Number(p.coverage_option) !== 3) return p;
  const id = await rentalcoverQuoteId(facts, source);
  return id ? { ...p, rentalcover_quote_id: id } : p;
}

/** After a request is saved: price its Protection Plan from a quote (the request form's renter and dates). */
export async function rentalcoverForRequest(bookingNumber: string): Promise<void> {
  const id = await rentalcoverQuoteId({ booking: bookingNumber }, 'request');
  if (id) await rpc('server_rentalcover_apply' as never, { p_booking: bookingNumber, p_quote: id } as never, SR).catch(() => undefined);
}
