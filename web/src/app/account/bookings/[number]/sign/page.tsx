import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { consents, when } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { bookingPath, carName } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { DetailsForm } from '@/features/portal/DetailsForm';
import { SignForm } from '@/features/portal/SignForm';
import { PrepareAgreement } from '@/features/portal/PrepareAgreement';
import { myBooking } from '@/server/portal/data';
import { agreementFacts, blocksFor, openAgreement, unsignedFacts } from '@/server/portal/agreement';
import { viewAs } from '@/server/view-as';
import { rpc } from '@/lib/db/repo';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your rental agreement', path: '/account/bookings', noindex: true, description: 'Read and sign the rental agreement for your booking.' });

// Your details and signature (02 section 5; simpler in 0049): the agreement for the approved offer, filled from the
// booking; the key values at the top with where to fix them, the full text one tap away (the same text as the PDF), the
// four statements ticked in one tap, and the signature (the legal name on file, or drawn).
export default async function SignPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'sign');
  if (b.status === 'offered') redirect(bookingPath(b.booking_number, 'offer'));
  // a rental staff added by hand (0046) is confirmed already: the renter signs it with no payment step after
  const added = !!(b as { added_by_staff?: boolean }).added_by_staff && b.status === 'confirmed';
  if (b.status !== 'pending_payment' && !added) redirect(bookingPath(b.booking_number));
  if (b.agreement?.renter_signed_at) redirect(added ? bookingPath(b.booking_number) : bookingPath(b.booking_number, 'pay'));
  // its agreement is made the first time the renter opens this page (there was no offer to approve)
  if (added && !b.agreement && !(await viewAs())) { await openAgreement(b.id, user.id); redirect(bookingPath(b.booking_number, 'sign')); }
  const facts = await agreementFacts(b.id, user.id);
  const r = facts.renter;
  const me = facts.drivers.find((d) => d.role === 'renter');
  const needDetails = !r?.address_line1 || !me?.licence_number || !me?.licence_expiry;
  const blocks = blocksFor(unsignedFacts(facts));
  const legal = r?.legal_name ?? me?.full_name ?? '';
  // a rental staff added with the saved card (0053): charged on "Accept and sign", never before
  const charge = added ? ((await rpc('server_manual_rental_sign_charge', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { amount_cents: number; brand: string | null; last4: string | null } | null) : null;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <header className="stack">
        <p className="pt-kicker">{added ? 'Your rental agreement' : 'Step 2 of 3 · Sign'}</p>
        <h1 className="d2">Sign your rental agreement</h1>
      </header>
      <div className="pt-strip" data-testid="sign-summary" role="group" aria-label="Summary">
        <div><span>Car</span>{carName(b)}</div>
        <div><span>Dates</span>{when(b.pickup_at)} to {when(b.return_at)}</div>
        {!added && <div><span>Due now</span>{money(b.renter_due_at_booking_cents, { cents: true })}</div>}
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
      {!b.agreement ? <PrepareAgreement number={b.booking_number} /> : (
        <div className="pt-split">
          <section className="stack" aria-labelledby="pt-read">
            <div className="pt-card__head"><h2 className="d4" id="pt-read">The agreement</h2><a className="link" href={`/account/documents/${b.agreement.document_id}`} data-testid="agreement-pdf">Download PDF</a></div>
            <p className="small muted">Filled in with your booking and your details above. The full text, word for word:</p>
            <details className="sg-docs"><summary>Read the full rental agreement</summary><AgreementView blocks={blocks} /></details>
          </section>
          <aside className="pt-split__aside">
            <section className="pt-card" aria-labelledby="pt-sign">
              <h2 className="d4" id="pt-sign">Sign</h2>
              {needDetails && <p className="alert alert--warn" role="note"><span>Add your details above first, so the agreement shows them.</span></p>}
              {charge && <p className="small" data-testid="sign-charge-note">Read and sign your rental agreement; your card is charged when you sign. We charge {money(charge.amount_cents, { cents: true })} to the card ending {charge.last4 ?? 'on file'} when you press Accept and sign.</p>}
              <SignForm number={b.booking_number} sha={b.agreement.document_sha256} consents={consents()} legalName={legal} fixNameHref="#pt-details" button={charge ? 'Accept and sign' : added ? 'Sign the agreement' : 'Sign and continue to payment'} />
              <p className="xs muted">We record the time, your IP address and device with your signature. The agreement is then countersigned by CarmaCars {added ? 'as soon as you sign' : 'when you pay'}. <Link prefetch={false} className="link" href="/privacy">Privacy</Link></p>
            </section>
          </aside>
        </div>
      )}
    </>
  );
}
