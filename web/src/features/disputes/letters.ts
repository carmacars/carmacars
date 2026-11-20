// r48 FE (3192): the cover letter of a dispute evidence pack, written per reason. Pure, for the PDF
// (server/agreements/dispute-pack.ts), the fields staged in Stripe and the tests. Card network reason codes as Stripe
// names them; the non-card variants (an e-Transfer or cash renter disputing a charge, insurer billing, a small claims court
// bundle) have their own letters.

export type Reason = 'fraudulent' | 'unrecognized' | 'product_not_received' | 'credit_not_processed' | 'duplicate' | 'subscription_canceled' | 'product_unacceptable' | 'general';
export type Variant = 'card' | 'etransfer_cash' | 'insurer' | 'small_claims';

export interface LetterCharge { label: string; amount_cents: number; clause: string; evidence: string[]; notice_sent_at: string | null; notice_status: string | null }
export interface LetterInput {
  reason: string | null; variant: Variant; bookingNumber: string; agreementNumber: string | null; renter: string; car: string; from: string; to: string;
  handedOver: string | null; returned: string | null; amountCents: number | null; charges: LetterCharge[];
  signedWithCode: boolean; signedAt: string | null; ip: string | null; idChecked: boolean; faceMatch: number | null; previousTrips: number; sameCardTrips: number;
  avs: string | null; cvc: string | null; threeDs: string | null; refundsCents: number; paymentsCount: number
}
export interface Letter { title: string; paragraphs: string[]; stripe: Record<string, string> }

const m = (c: number | null | undefined) => `$${((c ?? 0) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const d = (iso: string | null) => (iso ? iso.slice(0, 10) : 'not recorded');

/** Stripe's reason (or anything else) to the letter we write. */
export function reasonOf(r: string | null | undefined): Reason {
  const x = (r ?? '').toLowerCase();
  if (['fraudulent', 'unrecognized', 'product_not_received', 'credit_not_processed', 'duplicate', 'subscription_canceled', 'product_unacceptable'].includes(x)) return x as Reason;
  if (x === 'not_recognized' || x === 'not_recognised') return 'unrecognized';
  if (x === 'not_received' || x === 'service_not_received') return 'product_not_received';
  return 'general';
}

function chargesText(i: LetterInput): string[] {
  if (!i.charges.length) return [];
  return [`The charges after the rental, each under a clause the cardholder signed (rental agreement ${i.agreementNumber ?? ''}):`,
    ...i.charges.map((c) => `- ${c.label}: ${m(c.amount_cents)} plus tax, under ${c.clause}. Evidence: ${c.evidence.join(', ') || 'see the exhibits'}. The cardholder was told before it was billed${c.notice_sent_at ? ` on ${d(c.notice_sent_at)} (${c.notice_status ?? 'sent'})` : ''}.`)];
}

function proofOfPerson(i: LetterInput): string {
  const bits = [i.signedWithCode ? 'confirmed their identity with a one-time code sent to their own phone or email' : 'signed electronically',
    i.signedAt ? `on ${d(i.signedAt)}` : '', i.ip ? `from IP ${i.ip}` : '',
    i.idChecked ? `their driver's licence was checked${i.faceMatch !== null ? ` and their selfie matched it (score ${i.faceMatch})` : ''}` : '',
    i.avs ? `the address check was ${i.avs}` : '', i.cvc ? `the CVC check was ${i.cvc}` : '', i.threeDs ? `3D Secure: ${i.threeDs}` : ''].filter(Boolean);
  return `The cardholder ${bits.join('; ')}.`;
}

export function coverLetter(i: LetterInput): Letter {
  const reason = reasonOf(i.reason);
  const rental = `${i.renter} rented a ${i.car} from CarmaCars under booking ${i.bookingNumber}, from ${d(i.from)} to ${d(i.to)}. The car was handed over on ${d(i.handedOver)} and returned on ${d(i.returned)}; the check-out and check-in reports, with time- and GPS-stamped photos, are in the exhibits.`;
  const history = i.previousTrips || i.sameCardTrips ? `The same person has ${i.previousTrips} earlier completed rental(s) with us${i.sameCardTrips ? `, ${i.sameCardTrips} of them with this same card` : ''}, none disputed.` : '';
  const ch = chargesText(i);
  if (i.variant === 'insurer') {
    return { title: `Insurer billing: booking ${i.bookingNumber}`, stripe: {}, paragraphs: [
      `To the adjuster: this pack supports our invoice for the replacement rental of booking ${i.bookingNumber}.`, rental,
      'The insurer authorized the rental (the authorization letter and the claim number are in the exhibits); the daily rate, the days and the extras are on the invoice, with every message we exchanged.',
      ...ch, 'We ask that the balance be paid as invoiced.'] };
  }
  if (i.variant === 'small_claims') {
    return { title: `Small claims bundle: CarmaCars v. ${i.renter}`, stripe: {}, paragraphs: [
      `This bundle supports a claim of ${m(i.amountCents)} against ${i.renter} for booking ${i.bookingNumber}.`, rental, proofOfPerson(i),
      ...ch, `Each charge was notified before it was billed and is unpaid. The exhibits are numbered in the order they are referred to: the signed rental agreement with its certificate of completion, the condition reports, the notices with their delivery records, the receipts and invoices, the Tracker readings and the messages. ${history}`.trim()] };
  }
  if (i.variant === 'etransfer_cash') {
    return { title: `Charge dispute: booking ${i.bookingNumber}`, stripe: {}, paragraphs: [
      `This pack answers the renter's dispute of the charges on booking ${i.bookingNumber}, paid by e-Transfer or cash (${i.paymentsCount} payment(s) recorded with their references).`, rental, proofOfPerson(i), ...ch,
      'Every charge is under a clause the renter signed, was notified before it was billed, and is supported by the evidence listed.'] };
  }
  const base: Record<Reason, { title: string; lead: string; close: string; stripe: Record<string, string> }> = {
    fraudulent: { title: 'The cardholder made this rental', lead: 'The cardholder says they did not authorize this charge. They did: they booked, signed and picked up the car themselves, as the identity evidence shows.',
      close: 'The person who rented, signed and drove the car is the cardholder.', stripe: {} },
    unrecognized: { title: 'The cardholder will recognize this rental', lead: `The cardholder does not recognize the charge. It is their car rental from CarmaCars (booking ${i.bookingNumber}); the statement descriptor names CarmaCars and every receipt was emailed to them.`,
      close: 'The charge is the rental and its signed charges, described on the receipts the cardholder received.', stripe: {} },
    product_not_received: { title: 'The rental was provided', lead: 'The cardholder says the service was not received. The car was handed over to them and driven for the whole rental, as the signed check-out report, the photos and the Tracker show.',
      close: 'The service, the car rental, was provided in full.', stripe: { 'evidence[service_date]': d(i.handedOver ?? i.from) } },
    credit_not_processed: { title: 'No credit is owed', lead: `The cardholder says a credit was not processed. ${i.refundsCents > 0 ? `${m(i.refundsCents)} was refunded already (the refund is in the exhibits); ` : ''}No further credit is owed under the rental agreement: the deposit was applied only to the charges below, each under a signed clause.`,
      close: 'The cancellation and refund terms were accepted when signing; the amounts kept follow them.', stripe: { 'evidence[refund_refusal_explanation]': 'The amounts kept are charges under clauses of the signed rental agreement, each notified before billing with its evidence; any refund owed was made.' } },
    duplicate: { title: 'The charges are not duplicates', lead: 'The cardholder says they were charged twice. Each charge is separate: the rental and its deposit, and each later charge with its own clause, notice and evidence, as listed below.',
      close: 'No amount was charged twice.', stripe: { 'evidence[duplicate_charge_explanation]': 'Each payment is a separate item of the same rental (the rental, the deposit taken for signed charges, a later charge), listed with its clause and notice.' } },
    subscription_canceled: { title: 'A single rental, not a subscription', lead: 'The cardholder says a subscription was cancelled. This is one rental of fixed dates, with its later charges under the signed agreement; nothing renews by itself.',
      close: 'There was nothing to cancel: the rental ran its dates.', stripe: { 'evidence[cancellation_rebuttal]': 'One rental of fixed dates under a signed agreement; nothing renews automatically.' } },
    product_unacceptable: { title: 'The car was as described', lead: 'The cardholder says the service was not as described. The car was checked and photographed at pickup with the cardholder, who signed the report, and drove it for the rental.',
      close: 'The rental was provided as agreed and signed for.', stripe: {} },
    general: { title: 'The rental and its charges', lead: 'This pack shows the rental, the signed agreement and every charge with its clause, notice and evidence.', close: 'Every charge follows the agreement the cardholder signed.', stripe: {} }
  };
  const b = base[reason];
  const paragraphs = [b.lead, rental, proofOfPerson(i), ...ch, history, b.close].filter(Boolean);
  return { title: `${b.title} (reason: ${reason.replace(/_/g, ' ')})`, paragraphs, stripe: { ...b.stripe, 'evidence[uncategorized_text]': paragraphs.join('\n').slice(0, 20000) } };
}
