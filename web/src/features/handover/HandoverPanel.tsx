import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { lateLabel } from './late';
import { SendSigningLink } from './SendSigningLink';
import type { SigningState } from './types';

// The booking page's check-out, check-in and signing card (migration 0130), the same for an Admin and an assistant
// (Fleet, Sales, Customer service): "Check out (pickup)" on a confirmed booking, "Check in (return)" while it is on rent,
// each opening the field checklist (all sides, interior, odometer, fuel, plate, damage close-ups, readings, signatures);
// the photo report; the late return; "Sign now on this device" and "Text or email the signing link" while the rental
// agreement waits for a signature.
export async function HandoverPanel({ b, base, userId, aal, canHandover, canSign }: {
  b: { id: string; booking_number: string; status: string; return_at: string; checked_in_at?: string | null; minutes_late?: number | null; handed_over_at?: string | null };
  base: string; userId: string; aal?: 'aal1' | 'aal2' | null; canHandover: boolean; canSign: boolean;
}) {
  const signing = canSign && ['pending_payment', 'confirmed', 'on_rent'].includes(b.status)
    ? await door<SigningState>(userId, 'ops_read', 'in_person_signing', { booking: b.id }, aal).catch(() => null) : null;
  const unsigned = (signing?.agreement?.status === 'open' || signing?.agreement?.status === 'signed') ? (signing?.signers ?? []).filter((s) => !s.signed_at) : [];
  const renterUnsigned = unsigned.some((s) => s.role === 'renter');
  const late = lateLabel(b);
  const reported = ['on_rent', 'returned', 'closed'].includes(b.status);
  if (!canHandover && !unsigned.length && !reported && !late) return null;
  return (
    <Card title="Check-out, check-in and signing" testId="handover-panel" tone={late ? 'warn' : b.status === 'confirmed' || b.status === 'on_rent' ? 'next' : undefined}>
      <div className="stack">
        {late && <p className="ad-late" data-testid="booking-late"><b>{late}</b>{b.checked_in_at ? '' : '. Check the car in as soon as it is back: the late return charges follow the actual time.'}</p>}
        <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
          {canHandover && b.status === 'confirmed' && <Act ops action="handover_open" payload={{ booking: b.id, kind: 'pickup' }} label="Check out (pickup)" variant="primary" go={`${base}/handover/{job}`} testId="checkout-start" />}
          {canHandover && b.status === 'on_rent' && <Act ops action="handover_open" payload={{ booking: b.id, kind: 'return' }} label="Check in (return)" variant="primary" go={`${base}/handover/{job}`} testId="checkin-start" />}
          {reported && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/report`} data-testid="photo-report-link">Photo report</Link>}
          {(unsigned.length > 0 || (signing && !signing.agreement)) && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/sign-now`} data-testid="sign-now-link">Sign now on this device</Link>}
        </div>
        {canHandover && ['confirmed', 'on_rent'].includes(b.status) && <p className="small muted">{b.status === 'confirmed'
          ? 'The checklist: ready check, licence and card, odometer and fuel, the photo set (every side, wheels, interior, odometer and fuel gauge, plate), damage close-ups, then the renter and you sign. Photos upload in the background and wait on the phone without a connection.'
          : 'The checklist: odometer and fuel, keys, cleanliness, the photo set, comparison with the check-out, belongings, then the renter and you sign. The late, kilometre and fuel charges are written at once.'}</p>}
        {unsigned.length > 0 && <p className="small" data-testid="sign-waiting">Waiting for a signature: {unsigned.map((s) => s.name).join(', ')}.</p>}
        {renterUnsigned && <SendSigningLink booking={b.id} mobile={signing?.renter_mobile ?? null} email={signing?.renter_email ?? null} />}
      </div>
    </Card>
  );
}
