import { rpc } from '@/lib/db/repo';
import { knownFor, type RenterMissing } from '@/features/portal/renter-details';

// The rental agreement's blanks this renter fills in (migration 0195), while the agreement is in use (waiting for
// payment, confirmed, on rent). Read failures show nothing rather than blocking the page.
export const DETAIL_STATUSES = ['pending_payment', 'confirmed', 'on_rent'];
export async function renterDetailsMissing(b: { id: string; status: string; booking_type: string }, userId: string): Promise<RenterMissing[]> {
  if (!DETAIL_STATUSES.includes(b.status) || b.booking_type === 'owner') return [];
  return ((await rpc('renter_agreement_missing', { p_booking: b.id, p_by: userId }, { role: 'service_role' }).catch(() => [])) ?? []) as unknown as RenterMissing[];
}

/** Release 48 (2911, public.renter_prefill): what the renter already gave us (their profile, their licence, the
 *  coverage of their last booking), for the blanks asked, so they are never typed twice. Read on the server for the
 *  signed-in renter's own booking; only the asked fields reach the page. */
export async function renterDetailsKnown(b: { id: string }, userId: string, missing: RenterMissing[]): Promise<Record<string, string>> {
  if (!missing.length) return {};
  const p = ((await rpc('renter_prefill', { p_booking: b.id, p_by: userId }, { role: 'service_role' }).catch(() => null)) ?? null) as Record<string, unknown> | null;
  return knownFor(missing, p);
}

/** Release 48: with the details still missing and what the renter already gave us, the form's prefilled values. */
export async function renterDetails(b: { id: string; status: string; booking_type: string }, userId: string): Promise<{ missing: RenterMissing[]; known: Record<string, string> }> {
  const missing = await renterDetailsMissing(b, userId);
  return { missing, known: await renterDetailsKnown(b, userId, missing) };
}
