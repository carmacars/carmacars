import { rpc } from '@/lib/db/repo';
import type { RenterMissing } from '@/features/portal/renter-details';

// The rental agreement's blanks this renter fills in (migration 0195), while the agreement is in use (waiting for
// payment, confirmed, on rent). Read failures show nothing rather than blocking the page.
export const DETAIL_STATUSES = ['pending_payment', 'confirmed', 'on_rent'];
export async function renterDetailsMissing(b: { id: string; status: string; booking_type: string }, userId: string): Promise<RenterMissing[]> {
  if (!DETAIL_STATUSES.includes(b.status) || b.booking_type === 'owner') return [];
  return ((await rpc('renter_agreement_missing', { p_booking: b.id, p_by: userId }, { role: 'service_role' }).catch(() => [])) ?? []) as unknown as RenterMissing[];
}
