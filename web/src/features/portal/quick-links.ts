// r32 renter quick links (the renter home): what a booking still needs, one tap each. The existing rule: the licence from
// the request on, the proof of coverage after approval (pending payment, confirmed, or a rental added already underway).
export interface QuickLink { key: 'licence' | 'insurance' | 'card_coverage'; label: string; href: string }

export function quickLinks(b: { booking_number: string; status: string; added_mode?: string | null; coverage_confirmed_at?: string | null; missing?: string[] | null },
  licenceMissing: boolean): QuickLink[] {
  const verify = `/account/bookings/${encodeURIComponent(b.booking_number)}/verify`;
  const licenceTime = ['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) || (b.status === 'on_rent' && b.added_mode === 'in_progress');
  const coverageTime = ['pending_payment', 'confirmed'].includes(b.status) || (b.status === 'on_rent' && b.added_mode === 'in_progress');
  const out: QuickLink[] = [];
  if (licenceTime && (licenceMissing || (b.missing ?? []).includes('identity'))) out.push({ key: 'licence', label: 'Upload your licence', href: verify });
  if (coverageTime && !b.coverage_confirmed_at && (b.missing ?? ['coverage']).includes('coverage')) {
    out.push({ key: 'insurance', label: 'Upload proof of insurance', href: `${verify}#pt-cov` });
    out.push({ key: 'card_coverage', label: 'Check if your credit card covers rentals', href: '/credit-card-rental-coverage' });
  }
  return out;
}
