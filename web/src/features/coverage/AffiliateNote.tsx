import { coverageGo, type Placement } from '@/features/referral/model';

/**
 * The optional "coverage from another company" suggestion. It is a separate company's product: nothing here says what it covers,
 * and it never replaces the coverage option the renter picks. The link goes through /go/coverage (click counted, UTM added).
 */
export function AffiliateNote({ name, placement, booking }: { name: string; placement: Placement; booking?: string | null }) {
  const who = name || 'RentalCoverage';
  return (
    <p className="small muted measure" data-testid="coverage-affiliate">
      Looking for coverage from another company? <a className="link" href={coverageGo(placement, booking)} rel="sponsored nofollow noopener" target="_blank" data-testid="coverage-affiliate-link">See {who}</a>.
      {' '}{who} is a separate company and its product is optional. It is not issued or handled by us, and it does not replace the coverage option you choose with us. Check its terms for a rental in Ontario before you buy. We may earn a commission if you buy, at no extra cost to you.
    </p>
  );
}
