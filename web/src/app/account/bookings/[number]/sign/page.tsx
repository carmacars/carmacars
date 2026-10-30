import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { consents, when } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { bookingPath, carName } from '@/features/portal/status';
import { addedLive } from '@/features/portal/types';
import { Back } from '@/features/portal/Blocks';
import { DetailsForm } from '@/features/portal/DetailsForm';
import { SignForm } from '@/features/portal/SignForm';
import { PrepareAgreement } from '@/features/portal/PrepareAgreement';
import { myBooking } from '@/server/portal/data';
import { blocksFor, openAgreement, unsignedBundle } from '@/server/portal/agreement';
import { keyTerms, loadBundle } from '@/server/agreements/bundle';
import { viewAs } from '@/server/view-as';
import { companionOf, openCompanionQuietly } from '@/server/portal/blindspot';
import { rpc } from '@/lib/db/repo';
import { StepHeader } from '@/features/portal/trip';
import { myTripPhotos } from '@/server/portal/data';
import { CompleteDetails } from '@/features/portal/CompleteDetails';
import { renterDetailsMissing } from '@/server/portal/renter-details';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your rental agreement', path: '/account/bookings', noindex: true, description: 'Read and sign the rental agreement for your booking.' });

// Your details and signature (02 section 5; simpler in 0049): the agreement for the approved offer, filled from the
// booking; the key values at the top with where to fix them, the full text one tap away (the same text as the PDF), the
// four statements ticked in one tap, and the signature (the legal name on file, or drawn).
export default async function SignPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'sign');
  if (b.status === 'offered') redirect(bookingPath(b.booking_number, 'offer'));
  // a rental staff added by hand (0046) is confirmed already: the renter signs it with no payment step after; one added
  // while already underway (0074) is on trip, signed the same way (with a payment link, paid online after signing)
  const added = addedLive(b);
  // paid before signing (0185): confirmed already, signed the same way with no payment step after
  const noPay = added || !!b.paid_unsigned;
  if (b.status !== 'pending_payment' && !noPay) redirect(bookingPath(b.booking_number));
  if (b.agreement?.renter_signed_at) redirect(noPay && !b.link_due ? bookingPath(b.booking_number) : bookingPath(b.booking_number, 'pay'));
  // its agreement is made the first time the renter opens this page (there was no offer to approve)
  if (noPay && !b.agreement && !(await viewAs())) { await openAgreement(b.id, user.id); redirect(bookingPath(b.booking_number, 'sign')); }
  // the second agreement (Blind Spot's, 0127): made here when the rental agreement was opened before it was in use
  let companion = b.agreement?.status === 'open' ? await companionOf(b.id) : null;
  if (b.agreement?.status === 'open' && !companion && !(await viewAs())) { await openCompanionQuietly(b.id, user.id); companion = await companionOf(b.id); }
  const [bundle, photos, detailsMissing] = await Promise.all([loadBundle(b.id, user.id), myTripPhotos(user), renterDetailsMissing(b, user.id)]);
  const facts = bundle.f;
  const r = facts.renter;
  const me = facts.drivers.find((d) => d.role === 'renter');
  const needDetails = !r?.address_line1 || !me?.licence_number || !me?.licence_expiry;
  const ub = unsignedBundle(bundle);
  const blocks = blocksFor(ub.f, undefined, ub);
  const legal = r?.legal_name ?? me?.full_name ?? '';
  // a rental staff added with the saved card (0053): charged on "Accept and sign", never before
  const charge = added ? ((await rpc('server_manual_rental_sign_charge', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { amount_cents: number; brand: string | null; last4: string | null } | null) : null;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <StepHeader b={b} photo={photos[b.vehicle_id] ?? null} kicker={noPay ? 'Your rental agreement' : 'Step 2 of 3 · Sign'} title="Sign your rental agreement" step={noPay ? undefined : 2} />
      <div className="pt-strip" data-testid="sign-summary" role="group" aria-label="Summary">
        <div><span>Car</span>{carName(b)}</div>
        <div><span>Dates</span>{when(b.pickup_at)} to {when(b.return_at)}</div>
        {!noPay && <div><span>Due now</span>{money(b.renter_due_at_booking_cents, { cents: true })}</div>}
        {b.link_due && <div data-testid="sign-pay-after"><span>Paid online after you sign</span>{money(b.renter_due_at_booking_cents, { cents: true })}</div>}
        {charge && <div data-testid="sign-charge"><span>Charged when you sign</span>{money(charge.amount_cents, { cents: true })}</div>}
        <div><span>Deposit at pickup</span>{money(b.deposit_cents)}</div>
        <div><span>Deductible</span>{money(b.deductible_cents)}</div>
        <div><span>Cancellation</span>{b.booking_type === 'non_refundable' ? 'Non-refundable' : 'Standard tiers'}</div>
      </div>
      <p className="small muted" data-testid="sign-fix-line">Car, dates or price not right? <Link prefetch={false} className="link" href={bookingPath(b.booking_number)}>Message us from your booking</Link> before you sign. Your name, address or licence? Fix them under Your details below.</p>
      <section className={`pt-card${needDetails ? ' pt-card--next' : ''}`} aria-labelledby="pt-details">
        <h2 className="d4" id="pt-details">Your details</h2>
        {needDetails ? <p>The agreement needs your home address and licence details. Add them once; we keep them for next time.</p> : <p className="small muted">Your address and licence are on file. Change them here if they are not right.</p>}
        {needDetails ? <DetailsForm number={b.booking_number} initial={{ address_line1: r?.address_line1 ?? '', address_line2: r?.address_line2 ?? '', city: r?.city ?? '', province: r?.province ?? 'ON', postal_code: r?.postal_code ?? '', country: r?.country ?? 'Canada', licence_number: me?.licence_number ?? '', licence_class: me?.licence_class ?? 'G', licence_issuer: me?.licence_issuer ?? 'ON', licence_expiry: me?.licence_expiry ?? '' }} />
          : <details><summary className="link">Edit my details</summary><DetailsForm number={b.booking_number} initial={{ address_line1: r?.address_line1 ?? '', address_line2: r?.address_line2 ?? '', city: r?.city ?? '', province: r?.province ?? '', postal_code: r?.postal_code ?? '', country: r?.country ?? '', licence_number: me?.licence_number ?? '', licence_class: me?.licence_class ?? 'G', licence_issuer: me?.licence_issuer ?? 'ON', licence_expiry: me?.licence_expiry ?? '' }} /></details>}
      </section>
      {/* 0195: the agreement's blanks first; the agreement and the signature follow once they are saved */}
      {detailsMissing.length > 0 ? <CompleteDetails number={b.booking_number} missing={detailsMissing} then="sign" /> : !b.agreement ? <PrepareAgreement number={b.booking_number} /> : (
        <div className="pt-split">
          <section className="stack" aria-labelledby="pt-read">
            <div className="pt-card__head"><h2 className="d4" id="pt-read">The agreement</h2><a className="link" href={`/account/documents/${b.agreement.document_id}`} data-testid="agreement-pdf">Download PDF</a></div>
            <p className="small muted">Filled in with your booking and your details above. The full text, word for word:</p>
            <details className="sg-docs"><summary>Read the full rental agreement</summary><AgreementView blocks={blocks} /></details>
            {companion && (
              <div className="stack" data-testid="sign-companion">
                <div className="pt-card__head"><h3 className="d4">Blind Spot Car Rental agreement</h3><a className="link" href={`/account/documents/${companion.document_id}`} data-testid="companion-pdf">Download PDF</a></div>
                <p className="small muted">We rent under Blind Spot Car Rental&apos;s insurance, so your rental also has their agreement, filled in with the same booking and details. Your one signature below signs both agreements.</p>
              </div>
            )}
          </section>
          <aside className="pt-split__aside">
            <section className="pt-card" aria-labelledby="pt-sign">
              <h2 className="d4" id="pt-sign">Sign</h2>
              {needDetails && <p className="alert alert--warn" role="note"><span>Add your details above first, so the agreement shows them.</span></p>}
              {charge && <p className="small" data-testid="sign-charge-note">Read and sign your rental agreement; your card is charged when you sign. We charge {money(charge.amount_cents, { cents: true })} to the card ending {charge.last4 ?? 'on file'} when you press Accept and sign.</p>}
              <SignForm number={b.booking_number} sha={b.agreement.document_sha256} companionSha={companion?.status === 'open' ? companion.document_sha256 : null} consents={consents()} legalName={legal} fixNameHref="#pt-details" terms={keyTerms(bundle)} button={charge ? 'Accept and sign' : noPay ? 'Sign the agreement' : 'Sign and continue to payment'} />
              <p className="xs muted">We record the time, your IP address and device with your signature. The agreement is then countersigned by CarmaCars {noPay ? 'as soon as you sign' : 'when you pay'}. <Link prefetch={false} className="link" href="/privacy">Privacy</Link></p>
            </section>
          </aside>
        </div>
      )}
    </>
  );
}
