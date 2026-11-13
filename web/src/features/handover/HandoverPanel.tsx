import Link from '@/components/Link';
import { Act, type Field } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { lateLabel } from './late';
import { handoverPanelView, SIGNING_STATUSES } from './panel';
import { ReturnClaimCard } from './ReturnClaimCard';
import { SendSigningLink } from './SendSigningLink';
import type { SigningState } from './types';
import { HandoverOneScreen } from './HandoverOneScreen';
import { LateReturnDecide } from './LateReturnChoice';
import type { LateReturn } from './late-return';

// The booking page's check-in, check-out and signing card (migration 0130), the same for an Admin and an assistant
// (Fleet, Sales, Customer service): "Check in (pickup)" on a confirmed booking, "Check out (return)" while it is on rent,
// each opening the field checklist (all sides, interior, odometer, fuel, plate, damage close-ups, readings, signatures);
// the photo report; the late return; "Sign now on this device" and "Text or email the signing link" while the rental
// agreement waits for a signature (0185: waiting for payment too; what it shows is decided in panel.ts).
// Release 42 (2660): the first button opens the one-screen checklist, the same on every portal (Admin, the assistants,
// field staff); the form with photos from the gallery is folded under it. A car that came back late shows the late
// return choice here: nothing is charged for it until someone chooses.
// 0195: the car went out or came back but the checklist could not be done (no photos, no time): the actual time,
// km and fuel if known, and why. A pickup without the deposit or the renter's signature needs an Admin and a reason.
function recordFields(kind: 'pickup' | 'return'): Field[] {
  return [
    { name: 'at', label: kind === 'pickup' ? 'Actual pickup time' : 'Actual return time', type: 'datetime', value: new Date().toISOString(), required: true, hint: 'Now, or earlier. Late return charges follow this time.' },
    { name: 'odometer_km', label: 'Odometer (km), if known', type: 'number', min: 0 },
    { name: 'fuel_pct', label: 'Fuel or charge (%), if known', type: 'number', min: 0, max: 100 },
    { name: 'reason', label: 'Why the details come later', type: 'text', required: true, wide: true },
    ...(kind === 'pickup' ? [
      { name: 'deposit_waiver_reason', label: 'Admin: deposit not taken, waive it because', type: 'text', wide: true, hint: 'Only when the deposit is not taken. An Admin only.' },
      { name: 'signature_override_reason', label: 'Admin: no renter signature on the check-in report, because', type: 'text', wide: true, hint: 'An Admin only. Recorded on the booking.' }
    ] as Field[] : [])
  ];
}

export async function HandoverPanel({ b, base, userId, aal, canHandover, canSign }: {
  b: { id: string; booking_number: string; status: string; return_at: string; checked_in_at?: string | null; minutes_late?: number | null; handed_over_at?: string | null };
  base: string; userId: string; aal?: 'aal1' | 'aal2' | null; canHandover: boolean; canSign: boolean;
}) {
  const signing = canSign && (SIGNING_STATUSES as readonly string[]).includes(b.status)
    ? await door<SigningState>(userId, 'ops_read', 'in_person_signing', { booking: b.id }, aal).catch(() => null) : null;
  const late = lateLabel(b);
  // 2660: a late return is a choice (extension, extra days, the late fee, a custom amount, waived), never a charge by itself
  const lateReturn = b.checked_in_at && late && ['returned', 'closed'].includes(b.status)
    ? await door<LateReturn | null>(userId, 'ops_read', 'late_return', { booking: b.id }, aal).catch(() => null) : null;
  // 0195: the check-in or check-out reports recorded now whose photos and readings come later
  const pending = canHandover && ['on_rent', 'returned', 'closed'].includes(b.status)
    ? ((await door<{ details_pending?: Array<'pickup' | 'return'> }>(userId, 'ops_read', 'handover_report', { booking: b.id }, aal).catch(() => null))?.details_pending ?? []) : [];
  // 0185: in-person signing while the booking waits for payment too, and never an empty card
  const v = handoverPanelView({ status: b.status, canHandover, signing, late: !!late, detailsPending: pending });
  // 0532: the renter's "I've returned the car" report (Confirm or Deny), for everyone who checks a car in
  const claim = canHandover && ['on_rent', 'confirmed', 'returned', 'closed'].includes(b.status) ? <ReturnClaimCard booking={b.id} base={base} userId={userId} aal={aal} /> : null;
  if (!v.show) return claim;
  return (<>
    {claim}
    <Card title="Check-in, check-out and signing" testId="handover-panel" tone={late ? 'warn' : b.status === 'confirmed' || b.status === 'on_rent' ? 'next' : undefined}>
      <div className="stack">
        {late && !lateReturn?.late && <p className="ad-late" data-testid="booking-late"><b>{late}</b>{b.checked_in_at ? '' : '. Check the car in as soon as it is back. A late return is not charged by itself: you choose how when the car is back.'}</p>}
        {lateReturn?.late && <section aria-label="Late return" data-testid="booking-late"><h3 className="d4">Late return</h3><LateReturnDecide late={lateReturn} refresh={[base]} /></section>}
        {(v.checkout || v.checkin || v.report || v.signNow) && <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
          {v.checkout && <Act ops action="handover_open" payload={{ booking: b.id, kind: 'pickup' }} label="Start the check-in (pickup)" variant="primary" go={`${base}/handover/{job}`} testId="checkout-start" />}
          {v.checkin && <Act ops action="handover_open" payload={{ booking: b.id, kind: 'return' }} label="Start the check-out (return)" variant="primary" go={`${base}/handover/{job}`} testId="checkin-start" />}
          {v.addDetails.map((k) => <Act key={k} ops action="handover_open" payload={{ booking: b.id, kind: k }} label={`Add the ${k === 'pickup' ? 'check-in' : 'check-out'} photos and readings`} variant="primary" go={`${base}/handover/{job}`} testId={`add-details-${k}`} />)}
          {v.recordPickup && <Act ops action="handover_record_now" payload={{ booking: b.id, kind: 'pickup' }} label="Record the pickup now (details later)" testId="record-pickup-now" refresh={[base]}
            done="Pickup recorded. Fleet has a task to add the photos and readings." fields={recordFields('pickup')} />}
          {v.recordReturn && <Act ops action="handover_record_now" payload={{ booking: b.id, kind: 'return' }} label="Record the return now (details later)" testId="record-return-now" refresh={[base]}
            done="Return recorded. Fleet has a task to add the photos and readings; the deposit can be settled." fields={recordFields('return')} />}
          {v.report && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/report`} data-testid="photo-report-link">Photo report</Link>}
          {v.signNow && <Link prefetch={false} className={`btn ${v.checkout || v.checkin ? 'btn--ghost' : 'btn--primary'} btn--sm`} href={`${base}/sign-now`} data-testid="sign-now-link">Sign now on this device</Link>}
        </div>}
        {/* 0545: one screen: the time, km, fuel, many photos at once with the suggested angles, a note; the renter's own
            photos join the same report. The full checklist stays one tap away. */}
        {(v.checkout || v.checkin) && <p className="small muted">{b.status === 'confirmed'
          ? 'One screen on your phone: the ready check, the renter, licence and card, the odometer, fuel and keys (filled in when the car reports them), the photos one tap each, then the renter and you sign.'
          : 'One screen on your phone: the odometer, fuel, keys and cleanliness (filled in when known), the photos one tap each, the late return choice if the car is late, then the renter and you sign.'}</p>}
        {/* 0545: the form with photos from the gallery, a dashboard photo and a note; the renter's own photos join the same report */}
        {(v.checkout || v.checkin) && <details data-testid="one-screen"><summary className="small link">{v.checkout ? 'Check in with photos already taken (from the gallery)' : 'Check out with photos already taken (from the gallery)'}</summary>
          <HandoverOneScreen booking={b.id} number={b.booking_number} kind={v.checkout ? 'pickup' : 'return'} who="staff" refresh={[base]} isAdmin={base.startsWith('/admin')} /></details>}
        {v.addDetails.map((k) => <details key={`os-${k}`} data-testid={`one-screen-add-${k}`}><summary className="small link">Add photos and readings to the {k === 'pickup' ? 'check-in' : 'check-out'} on one screen</summary>
          <HandoverOneScreen booking={b.id} number={b.booking_number} kind={k} who="staff" refresh={[base]} /></details>)}
        {v.addDetails.length > 0 && <p className="small" data-testid="details-pending">{v.addDetails.map((k) => (k === 'pickup' ? 'The check-in' : 'The check-out')).join(' and ')} was recorded with the details later: add the photos, the readings and your signature with the checklist.</p>}
        {v.waiting.length > 0 && <p className="small" data-testid="sign-waiting">Waiting for a signature: {v.waiting.join(', ')}.</p>}
        {v.note && <p className="small muted" data-testid="sign-state">{v.note}</p>}
        {v.sendLink && <SendSigningLink booking={b.id} mobile={signing?.renter_mobile ?? null} email={signing?.renter_email ?? null} />}
      </div>
    </Card>
  </>);
}
