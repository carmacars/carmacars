import type { SigningState } from './types';

// What the booking page's "Check-out, check-in and signing" card shows (migration 0130), decided apart from the
// rendering so it is tested on its own. 0185: a booking waiting for payment (the renter accepted the offer online and
// left the pay page) showed the card empty: no check-out yet, and "Sign now on this device" only when the database's
// signing state listed someone unsigned. Now the card offers in-person signing whenever the rental agreement waits for a
// signature or is not made yet (pending payment, confirmed, on rent), says where the agreement stands otherwise, and is
// left out when it would have nothing in it.
export const SIGNING_STATUSES = ['pending_payment', 'confirmed', 'on_rent'] as const;

export interface PanelView {
  show: boolean;
  checkout: boolean;
  checkin: boolean;
  report: boolean;
  /** "Sign now on this device": someone still signs, or the agreement is not made yet (the page prepares it) */
  signNow: boolean;
  /** who still signs */
  waiting: string[];
  /** the renter has not signed: the signing link can be texted or emailed */
  sendLink: boolean;
  /** where the agreement stands, when there is no button for it */
  note: string | null;
  /** 0195: "Record the pickup now (details later)" / "Record the return now (details later)" */
  recordPickup: boolean;
  recordReturn: boolean;
  /** 0195: a check-out or check-in recorded with the details later: "Add the photos and readings" */
  addDetails: Array<'pickup' | 'return'>;
}

export function handoverPanelView(o: { status: string; canHandover: boolean; signing: SigningState | null; late: boolean;
  /** 0195: the reports of this booking waiting for their photos and readings */
  detailsPending?: Array<'pickup' | 'return'> }): PanelView {
  const s = o.signing;
  const inSigning = (SIGNING_STATUSES as readonly string[]).includes(o.status);
  const agreement = s?.agreement?.status ?? null;
  const unsigned = s && (agreement === 'open' || agreement === 'signed') ? s.signers.filter((g) => !g.signed_at) : [];
  const none = !!s && inSigning && !s.agreement;
  const signNow = inSigning && (unsigned.length > 0 || none);
  const renterUnsigned = unsigned.some((g) => g.role === 'renter');
  let note: string | null = null;
  if (s && inSigning) {
    if (none) note = 'No rental agreement is made yet: Sign now on this device prepares it, then the renter signs on your device.';
    else if (renterUnsigned && s.paid_unsigned) note = 'Paid. The renter has not signed the rental agreement yet: the car is not released until they do. CarmaCars countersigns as soon as they sign.';
    else if (renterUnsigned && o.status === 'pending_payment') note = 'The renter has not signed the rental agreement yet. They can sign now on your device, or online with the signing link. Payment can be recorded before or after.';
    else if (agreement === 'signed' && !unsigned.length) note = o.status === 'pending_payment'
      ? 'The renter signed the rental agreement. CarmaCars countersigns once the amount due at booking is paid (record it on Money).'
      : 'Everyone signed. CarmaCars countersigns the rental agreement automatically.';
    else if (agreement === 'completed' && o.status === 'pending_payment') note = 'The rental agreement is signed and countersigned.';
  }
  const checkout = o.canHandover && o.status === 'confirmed';
  const checkin = o.canHandover && o.status === 'on_rent';
  const report = ['on_rent', 'returned', 'closed'].includes(o.status);
  // 0195: the details of a pickup (once on rent) or a return (once returned) recorded now, added later
  const addDetails = o.canHandover ? (o.detailsPending ?? []).filter((k) => (k === 'pickup' ? ['on_rent', 'returned', 'closed'] : ['returned', 'closed']).includes(o.status)) : [];
  return {
    show: checkout || checkin || report || o.late || signNow || note !== null || addDetails.length > 0,
    checkout, checkin, report, signNow, waiting: unsigned.map((g) => g.name), sendLink: renterUnsigned, note,
    recordPickup: checkout, recordReturn: checkin, addDetails
  };
}
