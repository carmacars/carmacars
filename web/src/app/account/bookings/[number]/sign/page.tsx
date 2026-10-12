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
import { agreementFacts, blocksFor, unsignedFacts } from '@/server/portal/agreement';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign your rental agreement', path: '/account/bookings', noindex: true, description: 'Read and sign the rental agreement for your booking.' });

// Your details and signature (02 section 5): the agreement for the approved offer, filled from the
// booking, read on screen (the same text as the PDF), four consents and a drawn or typed signature.
export default async function SignPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'sign');
  if (b.status === 'offered') redirect(bookingPath(b.booking_number, 'offer'));
  if (b.status !== 'pending_payment') redirect(bookingPath(b.booking_number));
  if (b.agreement?.renter_signed_at) redirect(bookingPath(b.booking_number, 'pay'));
  const facts = await agreementFacts(b.id, user.id);
  const r = facts.renter;
  const me = facts.drivers.find((d) => d.role === 'renter');
  const needDetails = !r?.address_line1 || !me?.licence_number || !me?.licence_expiry;
  const blocks = blocksFor(unsignedFacts(facts));
  const legal = r?.legal_name ?? me?.full_name ?? '';
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <header className="stack">
        <p className="pt-kicker">Step 2 of 3 · Sign</p>
        <h1 className="d2">Sign your rental agreement</h1>
      </header>
      <div className="pt-strip" data-testid="sign-summary" role="group" aria-label="Summary">
        <div><span>Car</span>{carName(b)}</div>
        <div><span>Dates</span>{when(b.pickup_at)} to {when(b.return_at)}</div>
        <div><span>Due now</span>{money(b.renter_due_at_booking_cents, { cents: true })}</div>
        <div><span>Deposit at pickup</span>{money(b.deposit_cents)}</div>
        <div><span>Deductible</span>{money(b.deductible_cents)}</div>
        <div><span>Cancellation</span>{b.booking_type === 'non_refundable' ? 'Non-refundable' : 'Standard tiers'}</div>
      </div>
      <section className={`pt-card${needDetails ? ' pt-card--next' : ''}`} aria-labelledby="pt-details">
        <h2 className="d4" id="pt-details">Your details</h2>
        {needDetails ? <p>The agreement needs your home address and licence details. Add them once; we keep them for next time.</p> : <p className="small muted">Your address and licence are on file. Change them here if they are not right.</p>}
        {needDetails ? <DetailsForm number={b.booking_number} initial={{ address_line1: r?.address_line1 ?? '', address_line2: r?.address_line2 ?? '', city: r?.city ?? '', province: r?.province ?? 'ON', postal_code: r?.postal_code ?? '', country: r?.country ?? 'Canada', licence_number: me?.licence_number ?? '', licence_class: me?.licence_class ?? 'G', licence_issuer: me?.licence_issuer ?? 'ON', licence_expiry: me?.licence_expiry ?? '' }} />
          : <details><summary className="link">Edit my details</summary><DetailsForm number={b.booking_number} initial={{ address_line1: r?.address_line1 ?? '', address_line2: r?.address_line2 ?? '', city: r?.city ?? '', province: r?.province ?? '', postal_code: r?.postal_code ?? '', country: r?.country ?? '', licence_number: me?.licence_number ?? '', licence_class: me?.licence_class ?? 'G', licence_issuer: me?.licence_issuer ?? 'ON', licence_expiry: me?.licence_expiry ?? '' }} /></details>}
      </section>
      {!b.agreement ? <PrepareAgreement number={b.booking_number} /> : (
        <div className="pt-split">
          <section className="stack" aria-labelledby="pt-read">
            <div className="pt-card__head"><h2 className="d4" id="pt-read">Read the agreement</h2><a className="link" href={`/account/documents/${b.agreement.document_id}`} data-testid="agreement-pdf">Download PDF</a></div>
            <AgreementView blocks={blocks} />
          </section>
          <aside className="pt-split__aside">
            <section className="pt-card" aria-labelledby="pt-sign">
              <h2 className="d4" id="pt-sign">Sign</h2>
              {needDetails && <p className="alert alert--warn" role="note"><span>Add your details above first, so the agreement shows them.</span></p>}
              <SignForm number={b.booking_number} sha={b.agreement.document_sha256} consents={consents()} legalName={legal} button="Sign and continue to payment" />
              <p className="xs muted">We record the time, your IP address and device with your signature. The agreement is then countersigned by CarmaCars when you pay. <Link className="link" href="/privacy">Privacy</Link></p>
            </section>
          </aside>
        </div>
      )}
    </>
  );
}
