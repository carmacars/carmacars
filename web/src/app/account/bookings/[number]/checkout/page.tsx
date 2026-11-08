import Link from '@/components/Link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { consents, when } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { bookingPath, carName } from '@/features/portal/status';
import { addedLive } from '@/features/portal/types';
import { Back, PriceBreakdown } from '@/features/portal/Blocks';
import { DetailsForm } from '@/features/portal/DetailsForm';
import { SignForm } from '@/features/portal/SignForm';
import { PayForm } from '@/features/portal/PayForm';
import { PrepareAgreement } from '@/features/portal/PrepareAgreement';
import { ReceiptEmail } from '@/features/portal/ReceiptEmail';
import { CompleteDetails } from '@/features/portal/CompleteDetails';
import { StepHeader } from '@/features/portal/trip';
import { signPayOf, signPaySteps, signPayWords } from '@/features/portal/sign-pay';
import { myBooking, myTripPhotos } from '@/server/portal/data';
import { blocksFor, openAgreement, unsignedBundle } from '@/server/portal/agreement';
import { keyTerms, loadBundle } from '@/server/agreements/bundle';
import { viewAs } from '@/server/view-as';
import { companionOf, openCompanionQuietly } from '@/server/portal/blindspot';
import { rpc } from '@/lib/db/repo';
import { PUSH_BACK } from '@/server/portal/payment';
import { accountGate, GATE_MESSAGE } from '@/server/sign-in-settings';
import { renterDetailsMissing } from '@/server/portal/renter-details';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign and pay', path: '/account/bookings', noindex: true, description: 'Sign the rental agreement and pay for your booking, on one page.' });

const SR = { role: 'service_role' as const };

// Sign and pay (r33, the owner, November 7: "renters are confused... they need a clear way to SIGN and PAY and it should
// be EASY"): one page, mobile first. At the top what is left in one sentence with the amount and the two steps; then the
// agreement's summary and the signature; then the card form directly below, on the same page. What is left comes from
// the one rule (0750, app.sign_pay_state), the same the payment checks: a signature for an older version of the offer
// opens a fresh agreement here to sign (never sent to pay). The old /sign and /pay addresses land here.
export default async function SignAndPayPage({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { user, b } = await myBooking((await params).number, 'checkout');
  const sp0 = await searchParams;
  if (b.status === 'offered') redirect(bookingPath(b.booking_number, 'offer'));
  let s = signPayOf(b);
  const va = await viewAs();
  // nothing left to sign or pay: the booking
  if (s.step === 'none' || s.step === 'offer') redirect(`${bookingPath(b.booking_number)}${sp0.signed ? '?signed=1' : ''}`);
  // a rental staff added by hand (0046, 0074) or paid before signing (0185): signed with no payment step after
  const added = addedLive(b);
  const noPay = !s.pay_after;
  // signed for an older version of the offer, or no agreement yet: a fresh one for the current version, then this page
  if (s.step === 'sign' && !va && (s.stale || !b.agreement)) {
    const opened = await openAgreement(b.id, user.id).then(() => true).catch((e) => { console.error('sign and pay: open agreement', e); return false; });
    if (opened) redirect(bookingPath(b.booking_number, 'checkout'));
  }
  // the second agreement (Blind Spot's, 0127): made here when the rental agreement was opened before it was in use
  let companion = b.agreement?.status === 'open' ? await companionOf(b.id) : null;
  if (b.agreement?.status === 'open' && !companion && !va) { await openCompanionQuietly(b.id, user.id); companion = await companionOf(b.id); }
  const signing = s.step === 'sign' && b.agreement?.status === 'open';
  const paying = s.step === 'pay';
  const [bundle, photos, detailsMissing, gate, debitOk, debitDeposit, offline] = await Promise.all([
    signing ? loadBundle(b.id, user.id) : Promise.resolve(null), myTripPhotos(user), renterDetailsMissing(b, user.id),
    paying ? accountGate(user.id, 'pay') : Promise.resolve(null),
    // 0093 and 0230: a car marked no credit card needed, a booking an Admin allowed, or every booking per Settings
    Promise.all([rpc('vehicle_takes_debit', { p_vehicle: b.vehicle_id }, SR).catch(() => false), rpc('booking_takes_debit', { p_booking: b.id }, SR).catch(() => false)]).then(([v, k]) => v === true || k === true),
    // 0262: the deposit with a debit or prepaid card, once the booking takes one
    rpc('server_booking_debit_deposit', { p_booking: b.id }, SR).catch(() => null) as Promise<number | null>,
    // 0129: paid another way (e-Transfer, cash, a platform, the insurer): the way to pay instead of the card form
    rpc('renter_offline_pay_facts', { p_booking: b.id }, SR).catch(() => null) as unknown as Promise<{ rental_pay_method: string; deposit_pay_method: string; e_transfer_email: string | null; open_cents: number } | null>]);
  // 0750: a deposit charged (not held) on a debit or prepaid card carries the card processing fee, non-refundable
  const debitFee = debitDeposit ? Number((await rpc('server_debit_deposit_fee', { p_amount: debitDeposit }, SR).catch(() => 0)) ?? 0) : 0;
  s = signPayOf(b);
  const words = signPayWords(s);
  const steps = signPaySteps(s);
  const facts = bundle?.f;
  const r = facts?.renter;
  const me = facts?.drivers.find((d) => d.role === 'renter');
  const needDetails = !!facts && (!r?.address_line1 || !me?.licence_number || !me?.licence_expiry);
  const ub = bundle ? unsignedBundle(bundle) : null;
  const blocks = ub ? blocksFor(ub.f, undefined, ub) : [];
  const legal = r?.legal_name ?? me?.full_name ?? '';
  // a rental staff added with the saved card (0053): charged on "Accept and sign", never before
  const charge = added && signing ? ((await rpc('server_manual_rental_sign_charge', { p_booking: b.id, p_by: user.id }, SR).catch(() => null)) as unknown as { amount_cents: number; brand: string | null; last4: string | null } | null) : null;
  const live = !!b.link_due;
  const payOffline = !!offline && offline.rental_pay_method !== 'card' && b.status === 'pending_payment' && !live;
  const due = money(s.due_cents || b.renter_due_at_booking_cents, { cents: true });
  const depositLine = `The refundable deposit of ${money(b.deposit_cents)} is held on your card on the day of pickup${debitDeposit ? ` (${money(debitDeposit)} on a debit or prepaid card)` : ''}.`;
  const details = (country: string) => ({ address_line1: r?.address_line1 ?? '', address_line2: r?.address_line2 ?? '', city: r?.city ?? '', province: r?.province ?? country, postal_code: r?.postal_code ?? '', country: r?.country ?? (country ? 'Canada' : ''), licence_number: me?.licence_number ?? '', licence_class: me?.licence_class ?? 'G', licence_issuer: me?.licence_issuer ?? 'ON', licence_expiry: me?.licence_expiry ?? '' });

  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <StepHeader b={b} photo={photos[b.vehicle_id] ?? null} kicker={noPay ? 'Your rental agreement' : 'Sign and pay'} title={noPay ? 'Sign your rental agreement' : live ? 'Sign and pay for your rental' : 'Sign and pay for your booking'} />
      {words && (
        <section className="sp-left" aria-labelledby="sp-left-h" data-testid="sign-pay-left" data-step={s.step}>
          <h2 className="sp-left__title" id="sp-left-h">{words.title}</h2>
          <p className="sp-left__text" data-testid="sign-pay-left-text">{words.left}</p>
          {steps.length > 1 && <ol className="sp-steps" aria-label="Steps" data-testid="sign-pay-steps">{steps.map((x) => <li key={x.label} data-state={x.state} aria-current={x.state === 'now' ? 'step' : undefined}>{x.label}{x.state === 'done' ? <span className="vh"> (done)</span> : null}</li>)}</ol>}
        </section>
      )}
      {sp0.signed && paying && <p className="alert alert--ok" role="status" data-testid="sign-pay-signed"><span>Signed. Now pay {due} below to confirm your booking.</span></p>}

      {/* ---------------------------------------------------------------- 1. sign */}
      <section className="stack sp-section" id="sign" aria-labelledby="sp-sign-h" data-testid="sign-pay-sign">
        <h2 className="d3" id="sp-sign-h">{steps.length > 1 ? '1. Sign' : 'Sign'}</h2>
        {s.step !== 'sign' ? (
          <div className="pt-card" data-testid="sign-pay-signed-card">
            <p><b>Signed{s.signed_at ? ` ${when(s.signed_at)}` : ''}.</b> {b.agreement && <a className="link" href={`/account/documents/${b.agreement.document_id}`}>Your agreement (PDF)</a>}</p>
            {s.step === 'drivers' && <p data-testid="sign-pay-drivers">Waiting for {s.waiting.join(', ')} to sign: each has a signing link by email. <Link prefetch={false} className="link" href={`${bookingPath(b.booking_number)}#drivers`}>Send a new link</Link></p>}
          </div>
        ) : (
          <>
            {s.stale && va && <p className="alert alert--warn" role="note" data-testid="sign-pay-stale"><span>The offer was updated after the renter signed: a fresh agreement opens when the renter opens this page.</span></p>}
            <div className="pt-strip" data-testid="sign-summary" role="group" aria-label="Summary">
              <div><span>Car</span>{carName(b)}</div>
              <div><span>Dates</span>{when(b.pickup_at)} to {when(b.return_at)}</div>
              {!noPay && <div data-testid={live ? 'sign-pay-after' : 'sign-due-now'}><span>{live ? 'Paid online after you sign' : 'Due now'}</span>{due}</div>}
              {charge && <div data-testid="sign-charge"><span>Charged when you sign</span>{money(charge.amount_cents, { cents: true })}</div>}
              <div><span>Deposit (on the day of pickup)</span>{money(b.deposit_cents)}</div>
              <div><span>Deductible</span>{money(b.deductible_cents)}</div>
              <div><span>Cancellation</span>{b.booking_type === 'non_refundable' ? 'Non-refundable' : 'Standard tiers'}</div>
            </div>
            <p className="small muted" data-testid="sign-fix-line">Car, dates or price not right? <Link prefetch={false} className="link" href={bookingPath(b.booking_number)}>Message us from your booking</Link> before you sign.</p>
            {detailsMissing.length > 0 ? <CompleteDetails number={b.booking_number} missing={detailsMissing} then="sign" />
              : !signing || !b.agreement ? <PrepareAgreement number={b.booking_number} /> : (
              <>
                <section className={`pt-card${needDetails ? ' pt-card--next' : ''}`} aria-labelledby="pt-details">
                  <h3 className="d4" id="pt-details">Your details</h3>
                  {needDetails ? <><p>The agreement needs your home address and licence details. Add them once; we keep them for next time.</p><DetailsForm number={b.booking_number} initial={details('ON')} /></>
                    : <details><summary className="link">Your address and licence are on file. Edit them</summary><DetailsForm number={b.booking_number} initial={details('')} /></details>}
                </section>
                <section className="pt-card stack" aria-labelledby="pt-read">
                  <div className="pt-card__head"><h3 className="d4" id="pt-read">The agreement</h3><a className="link" href={`/account/documents/${b.agreement.document_id}`} data-testid="agreement-pdf">Download PDF</a></div>
                  <p className="small muted">Filled in with your booking and your details. The full text, word for word:</p>
                  <details className="sg-docs"><summary>Read the full rental agreement</summary><AgreementView blocks={blocks} /></details>
                  {companion && (
                    <div className="stack" data-testid="sign-companion">
                      <div className="pt-card__head"><h4 className="d4">Blind Spot Car Rental agreement</h4><a className="link" href={`/account/documents/${companion.document_id}`} data-testid="companion-pdf">Download PDF</a></div>
                      <p className="small muted">We rent under Blind Spot Car Rental&apos;s insurance, so your rental also has their agreement, filled in with the same booking and details. Your one signature below signs both agreements.</p>
                    </div>
                  )}
                </section>
                <section className="pt-card" aria-labelledby="pt-sign">
                  <h3 className="d4" id="pt-sign">Your signature</h3>
                  {needDetails && <p className="alert alert--warn" role="note"><span>Add your details above first, so the agreement shows them.</span></p>}
                  {charge && <p className="small" data-testid="sign-charge-note">Your card is charged when you sign: {money(charge.amount_cents, { cents: true })} to the card ending {charge.last4 ?? 'on file'} when you press Accept and sign.</p>}
                  <SignForm number={b.booking_number} sha={b.agreement.document_sha256} companionSha={companion?.status === 'open' ? companion.document_sha256 : null} consents={consents()} legalName={legal} fixNameHref="#pt-details" terms={bundle ? keyTerms(bundle) : []}
                    button={charge ? 'Accept and sign' : noPay ? 'Sign the agreement' : `Sign, then pay ${due} below`} />
                  <p className="xs muted">We record the time, your IP address and device with your signature. CarmaCars countersigns {noPay ? 'as soon as you sign' : 'when you pay'}. <Link prefetch={false} className="link" href="/privacy">Privacy</Link></p>
                </section>
              </>
            )}
          </>
        )}
      </section>

      {/* ---------------------------------------------------------------- 2. pay, directly below */}
      {s.pay_after && (
        <section className={`stack sp-section${paying ? '' : ' sp-locked'}`} id="pay" aria-labelledby="sp-pay-h" data-testid="sign-pay-pay">
          <h2 className="d3" id="sp-pay-h">2. Pay {due}</h2>
          {!paying ? <p className="pt-card" data-testid="sign-pay-pay-locked">The card form opens here as soon as {s.step === 'drivers' ? 'every driver has signed' : 'you sign'}. {depositLine}</p>
            : b.status !== 'pending_payment' && !live ? (
              <div className="pt-card pt-card--next" role="alert" data-testid="pay-pushed-back"><h3 className="d4">Nothing to pay</h3><p>{PUSH_BACK}</p></div>
            ) : (
              <div className="pt-split">
                {payOffline && offline ? (
                  <section className="pt-card stack" aria-labelledby="pt-pay" data-testid="pay-offline"><h3 className="d4" id="pt-pay">How you pay</h3>
                    {offline.rental_pay_method === 'e_transfer' ? <p>Send an Interac e-Transfer of <b>{money(offline.open_cents, { cents: true })}</b> to <b>{offline.e_transfer_email}</b>, with <b>{b.booking_number}</b> as the message. We confirm your booking as soon as it arrives.</p>
                      : offline.rental_pay_method === 'cash' ? <p>Pay <b>{money(offline.open_cents, { cents: true })}</b> in cash, as agreed with our team. We confirm your booking when it is received.</p>
                      : offline.rental_pay_method === 'insurer' ? <p>Your insurer is billed for this rental: nothing to pay now. We confirm your booking shortly.</p>
                      : offline.rental_pay_method === 'platform_payout' ? <p>This rental is paid on the platform you booked through: nothing to pay here. We confirm your booking shortly.</p>
                      : <p>Pay <b>{money(offline.open_cents, { cents: true })}</b> as agreed with our team ({offline.rental_pay_method.replace(/_/g, ' ')}). We confirm your booking when it is received.</p>}
                    <p className="small">{offline.deposit_pay_method === 'card' ? depositLine : offline.deposit_pay_method === 'none' ? 'No deposit on this booking.' : `The refundable deposit of ${money(b.deposit_cents)} is paid ${offline.deposit_pay_method === 'cash' ? 'in cash' : 'by e-Transfer'} and given back the same way.`}</p>
                  </section>
                ) : (
                  <section className="pt-card" aria-labelledby="pt-pay"><h3 className="d4" id="pt-pay">Card</h3>
                    {detailsMissing.length > 0 ? <CompleteDetails number={b.booking_number} missing={detailsMissing} then="pay" />
                      : gate?.ok ? <PayForm number={b.booking_number} amountCents={b.renter_due_at_booking_cents} depositCents={b.deposit_cents} coverageOption={b.coverage_option} debitOk={debitOk} />
                      : gate?.reason === 'email_needed' ? <ReceiptEmail path={bookingPath(b.booking_number, 'checkout')} />
                      : <p className="alert alert--error" role="alert" data-testid="pay-unconfirmed"><span>{GATE_MESSAGE} <Link prefetch={false} className="link" href="/account/profile">Profile</Link></span></p>}
                  </section>)}
                <aside className="pt-split__aside pt-first">
                  <section className="pt-card" aria-labelledby="pt-sum"><h3 className="d4" id="pt-sum">What you pay now</h3>
                    <PriceBreakdown lines={b.lines.filter((l) => l.stage === 'booking')} hst={b.hst_at_booking_cents} total={b.renter_due_at_booking_cents} insurer={b.insurer_pays_cents || undefined} deposit={b.deposit_cents} />
                    {debitDeposit && debitOk && debitFee > 0 ? <p className="small" data-testid="debit-deposit-fee">On a debit or prepaid card the deposit may be charged instead of held: then a non-refundable card processing fee for a debit deposit of {money(debitFee, { cents: true })} is added to it. The deposit itself is refunded after the return.</p> : null}
                  </section>
                </aside>
              </div>
            )}
        </section>
      )}
    </>
  );
}
