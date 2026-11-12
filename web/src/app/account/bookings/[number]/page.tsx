import { signPayOf, signPayOpen } from '@/features/portal/sign-pay';
import { Moment } from '@/features/motion/Moment';
import { ConfirmedOnce } from '@/features/motion/Progress';
import Link from '@/components/Link';
import { InfoTip } from '@/components/InfoTip';
import { seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getFleet, getSettings } from '@/lib/site';
import { when } from '@/features/agreement/model';
import { AWAITING_SIGNATURE, STATUS, awaitingSignature, bookingPath, nextStep, progress } from '@/features/portal/status';
import { returnReportable, selfPickupOffered } from '@/features/returns/claim';
import { Back, PriceBreakdown } from '@/features/portal/Blocks';
import { AddToCalendar } from '@/features/portal/AddToCalendar';
import { walletReady } from '@/server/wallet';
import { InfoReply } from '@/features/portal/InfoReply';
import { Messages, type Msg } from '@/features/portal/Messages';
import { rpc } from '@/lib/db/repo';
import { Withdraw } from '@/features/portal/Withdraw';
import { ChangeRequestActions } from '@/features/portal/SelfService';
import { myBooking, myTripPhotos, reviewState } from '@/server/portal/data';
import { LicenceNotice, licenceState, renterMissing } from '@/features/portal/LicenceNotice';
import { door } from '@/server/door';
import { bookingDriverLinks } from '@/server/portal/driver-links';
import { DriverLink } from '@/features/portal/DriverLink';
import { PushInvite } from '@/features/push/PushAlerts';
import { PortalAddons, type MyAddons } from '@/features/addons/PortalAddons';
import { renterPayBalance } from '@/server/actions/balance';
import type { HandoverReportData } from '@/features/handover/types';
import { AnimatedNumber, Disclosure, DocumentList, DocumentRow, MoneyCard, PortalCard, ProgressRing, QuickAction, QuickActions, type MoneyPart } from '@/components/portal-ui';
import { TripHero, ourAddress, tripPhoto } from '@/features/portal/trip';
import { placeText } from '@/features/portal/Blocks';
import { nextAction, stageSummary, stages } from '@/features/portal/next-action';
import { NextActionPanel } from '@/features/portal/NextActionPanel';
import { StepTracker } from '@/features/portal/StepTracker';
import { moneyParts } from '@/features/portal/trip-model';
import { CompleteDetails } from '@/features/portal/CompleteDetails';
import { StillNeeded } from '@/features/portal/StillNeeded';
import { showNeeds, stillNeededOf } from '@/features/portal/still-needed';
import { renterDetailsMissing } from '@/server/portal/renter-details';
import { STAGES, type Walk } from '@/features/walkthrough/model';
import { AccidentSummary } from '@/features/accident-card/AccidentCard';
import { AccidentReport } from '@/features/accident-card/AccidentReport';
import { incidentHref } from '@/features/incident-cards/digital';
import type { AccidentCardData } from '@/features/accident-card/model';
import { READING_CHARGE_KEYS } from '@/features/handover/reading';
import { SecondaryContactForm, type ContactValue } from '@/features/portal/SecondaryContactForm';

export const dynamic = 'force-dynamic';
export async function generateMetadata({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  return seoMeta({ title: `Booking ${n}`, path: `/account/bookings/${n}`, noindex: true, description: 'Your booking: status, next step, price, drivers and documents.' });
}

const CHANGE: Record<string, string> = { requested: 'asked for, waiting for our answer', proposed: 'suggested by us, waiting for your answer', approved: 'approved, waiting for your signature',
  applied: 'done', declined: 'declined', cancelled: 'withdrawn', expired: 'not accepted in time' };

const BADGE: Record<string, string> = { id_front: 'ID', id_back: 'ID', face: 'IMG', condition_report: 'PDF' };
const KIND: Record<string, string> = { rental_amendment: 'Booking amendment', rental_agreement: 'Rental agreement', receipt: 'Receipt', renter_statement: 'Statement', condition_report: 'Condition Report', coverage_proof: 'Proof of coverage', id_front: 'Licence, front', id_back: 'Licence, back', face: 'Selfie' };
// what the renter asks for in a message, from an action tile (?ask=): the message box starts with it
const ASK: Record<string, string> = {
  driver: 'I would like to add a driver to this booking. Their name: ',
  problem: 'I have a problem with the car: ',
  extend: 'I would like to keep the car longer, until: '
};

export default async function BookingPage({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { b, user } = await myBooking((await params).number);
  // receipts and statements, rendered on request and kept once final (migration 0032)
  const [files, thread, photos, fleet] = await Promise.all([
    door<Array<{ kind: string; key: string; title: string; at: string }>>(user.id, 'ops_read', 'files', { for: 'booking', id: b.id }).catch(() => []),
    // the booking's messages, read as the signed-in renter (migration 0033)
    rpc('my_booking_messages', { p_number: b.booking_number }, { role: 'authenticated', userId: user.id }).then((x) => (x ?? []) as unknown as Msg[]).catch(() => [] as Msg[]),
    myTripPhotos(user), getFleet().catch(() => [])]);
  const [sp, s, addons, report, walk] = await Promise.all([searchParams, getSettings(),
    // the add-ons on the booking and what may still be added (0066)
    b.booking_type === 'owner' ? Promise.resolve(null) : rpc('server_my_booking_addons', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as MyAddons).catch(() => null),
    // the kilometres driven, once the car is back (the photo report's reading, 0130)
    b.checked_in_at ? rpc('server_renter_handover_report', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as HandoverReportData | null).catch(() => null) : Promise.resolve(null),
    // the rental walkthrough (0291): how far the renter is, for the card that opens it
    rpc('server_my_walkthrough', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as Walk | null).catch(() => null)]);
  // 0910: the accident card of this booking (its own coverage), from confirmation to the return
  const accident = ['pending_payment', 'confirmed', 'on_rent'].includes(b.status) && b.booking_type !== 'owner'
    ? await rpc('server_accident_card' as never, { p_booking: b.id, p_by: user.id } as never, { role: 'service_role' }).then((x) => x as unknown as AccidentCardData).catch(() => null) : null;
  // r35a (1302): the secondary contact of this booking (else the profile's)
  const second = b.booking_type !== 'owner' && !['closed', 'cancelled', 'declined', 'expired'].includes(b.status)
    ? await rpc('server_secondary_contact', { p_by: user.id, p_booking: b.id }, { role: 'service_role' }).then((x) => x as unknown as { profile: ContactValue | null; booking: ContactValue | null }).catch(() => null) : null;
  const rideshareOpen = b.booking_type !== 'owner' && ['pending_payment', 'confirmed', 'on_rent'].includes(b.status);
  const readingCharges = (report?.charges ?? []).filter((c) => READING_CHARGE_KEYS.has(c.key) && c.amount_cents !== 0);
  const laterLines = new Set((addons?.items ?? []).filter((a) => a.after_booking).map((a) => a.line_item_id).filter(Boolean));
  const step = nextStep(b);
  // what is still owing after a change by our team (0132): the balance, with Pay
  const balance = ['confirmed', 'on_rent', 'returned'].includes(b.status)
    ? ((await rpc('renter_balance', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { balance_cents: number } | null) : null;
  const balanceDue = balance && balance.balance_cents > 0 ? balance.balance_cents : 0;
  // the licence first (0130): from the request until it is on file
  const licMissing = ['requested', 'offered', 'pending_payment'].includes(b.status) ? renterMissing(await licenceState(b.id, user.id)) : null;
  // the agreement's blanks the renter fills in (0195): a blocking step at the top, before signing and paying
  const detailsMissing = await renterDetailsMissing(b, user.id);
  const openQ = b.info_requests.filter((q) => q.status === 'open');
  // each additional driver's own signing link (migration 0040: versioned, expiring, renewed here)
  const links = b.agreement && b.drivers.some((d) => d.role === 'additional') ? await bookingDriverLinks(b.id, user.id) : [];
  const waiting = b.change_requests.find((c) => ['proposed', 'approved'].includes(c.status));
  const live = ['confirmed', 'on_rent'].includes(b.status);
  const wallet = live && walletReady();
  const ext = b.extensions[b.extensions.length - 1];
  const phone = s.phone_display ?? s.phone;
  const tel = s.phone ?? phone;
  const roadside = s.roadside_phone ?? null;
  const card = b.payments.find((p) => p.purpose === 'booking_total' && p.card_last4);
  const photo = tripPhoto(photos, b, fleet.find((c) => c.slug === b.slug)?.cover ?? null);
  // 0750: the one rule (the Sign and pay page and the payment read the same)
  const rule = signPayOf(b);
  const signed = rule.signed || (!signPayOpen(rule) && !!b.agreement?.renter_signed_at);
  // the hero's next step names the action the tests and the guide know (live-sign, live-pay)
  const stepId = b.status === 'on_rent' && b.added_live && !signed ? 'live-sign' : b.link_due && signed ? 'live-pay' : 'booking-next-step-cta';
  // r40: the booking's steps in six plain stages (done, now, later), from progress()
  const track = stages(progress(b), b.status);
  const reviewDue = b.status === 'closed' && b.booking_type !== 'owner' ? await reviewState(user, b.id).then((r) => !r.review && !!r.can_review).catch(() => false) : false;
  const addr = ourAddress(s);
  const act = nextAction(b, step, { pickupPlace: placeText(b.pickup_place ?? addr, b.pickup_method, true), returnPlace: placeText(b.return_place ?? addr, b.return_method, false),
    balanceCents: balanceDue, needs: stillNeededOf(b), reviewDue });

  // money: what is paid and what is open, by part, as the database stored it
  const m = moneyParts({ status: b.status, renter_due_at_booking_cents: b.renter_due_at_booking_cents, deposit_cents: b.deposit_cents, link_due: b.link_due, signed,
    payments: b.payments, refunds: b.refunds, extensions: b.extensions, addons: addons?.items ?? [], changes: b.change_requests });
  const parts: MoneyPart[] = m.parts.map((p) => ({ key: p.key, label: p.key === 'deposit' ? <>{p.label}<InfoTip k="deposit" topic="the deposit" testId="info-deposit" /></> : p.label, amount: money(p.cents, { cents: true }), state: p.state, note: p.note,
    href: p.sub ? bookingPath(b.booking_number, p.sub) : undefined, cta: p.state === 'owing' || p.state === 'info' ? p.cta : undefined, testId: `money-${p.key}` }));
  // a rental with a payment link already shows its whole amount as owing
  if (balanceDue && !b.link_due) parts.push({ key: 'owe-balance', label: 'Balance due', amount: money(balanceDue, { cents: true }), state: 'owing', note: 'after a change or a charge added', testId: 'money-owe-balance' });
  const owingCents = m.owingCents + (b.link_due ? 0 : balanceDue);
  const firstOwing = m.parts.find((p) => p.state === 'owing');
  const receipts = [...b.documents.filter((d) => !d.purged && ['receipt', 'renter_statement'].includes(d.kind)).map((d) => ({ key: d.id, kind: d.kind, title: KIND[d.kind] ?? d.title ?? 'Receipt', at: d.created_at, href: `/account/documents/${d.id}` })),
    ...files.filter((f) => ['receipt', 'renter_statement', 'statement'].includes(f.kind)).map((f) => ({ key: `${f.kind}:${f.key}`, kind: f.kind, title: f.title, at: f.at, href: `/files/${f.kind}/${f.key}` }))];

  const next = <NextActionPanel a={act} testId="booking-next-step" titleId="booking-next-step-h" primaryTestId={stepId} dropTrip
    extra={live ? <><AddToCalendar number={b.booking_number} car={`${b.vehicle_year} ${b.vehicle_make} ${b.vehicle_model}`} pickup={b.pickup_at} ret={b.return_at} place={b.pickup_place ?? 'CarmaCars'} />{wallet && <a className="btn now__btn" href={bookingPath(b.booking_number, 'wallet')} data-testid="add-to-wallet">Add to Apple Wallet</a>}{phone && <a className="btn now__btn" href={`tel:${tel}`}>Call us {phone}</a>}</> : null} />;

  return (
    <>
      <Back href="/account">Your trips</Back>
      {sp.changed && <div className="pt-ok" role="status" data-testid="changed-panel"><h2 className="d3">Booking updated</h2><p>Your booking has the new details. The signed amendment is under Documents, and we emailed you a copy.</p></div>}
      {sp.declined && <div className="pt-ok" role="status" data-testid="declined-panel"><h2 className="d3">Change declined</h2><p>Your booking stays as it was. We let our team know.</p></div>}
      {sp.paid && b.status === 'on_rent' && b.added_live && !b.link_due && <div className="pt-ok" role="status" data-testid="paid-live-panel"><h2 className="d3">Paid, thank you</h2><p>Your card was charged {money(b.renter_due_at_booking_cents, { cents: true })} for your rental. Your signed agreement and receipt are below.</p></div>}
      {b.status === 'confirmed' && <PushInvite portal="renter" home={`/account/bookings/${b.booking_number}`} moment={{ key: 'booked', title: 'Get your pickup reminders as alerts', text: 'Pickup details, return reminders and messages from us on this device, the moment they happen.' }} />}
      {/* r35 S2: paid: the confirmed moment (a check, confetti, the car keys) */}
      {sp.paid && (b.status === 'confirmed' || b.status === 'on_rent') && <Moment kind="confirmed" />}
      {/* r36: confirmed without the pay page (staff confirmed it, paid another way): the moment once on this device */}
      {b.status === 'confirmed' && <ConfirmedOnce booking={b.booking_number} silent={!!sp.paid} />}
      {sp.paid && b.status === 'confirmed' && <div className="pt-ok" role="status" data-testid="paid-panel"><h2 className="d3">Booking confirmed</h2><p>Your card was charged {money(card?.amount_cents ?? b.renter_due_at_booking_cents, { cents: true })} and the car is reserved for you. Your signed agreement and receipt are below.</p></div>}

      {detailsMissing.length > 0 && <CompleteDetails number={b.booking_number} missing={detailsMissing} />}
      {/* r40 "Do this next": the one action and its button, then the steps; nothing above it competes */}
      {next}
      {!['cancelled', 'declined', 'expired', 'closed'].includes(b.status) && (
        <PortalCard id="pt-prog" title={stageSummary(track).text} testId="trip-progress"><StepTracker number={b.booking_number} stages={track} /></PortalCard>
      )}
      {(() => { const n = stillNeededOf(b); return showNeeds(n) ? <StillNeeded quiet number={b.booking_number} needs={n} title={b.status === 'requested' || b.status === 'offered' ? 'What we still need for this request' : undefined} testId="still-needed" /> : null; })()}
      <TripHero b={b} photo={photo} settings={s} kmDriven={report?.km_driven ?? null} prepaidFuel={(addons?.items ?? []).some((a) => a.prepaid_fuel)}>
        <p className="small muted" data-testid="status-blurb">{awaitingSignature(b) ? AWAITING_SIGNATURE.blurb : STATUS[b.status].blurb}
          {b.status === 'confirmed' && <> Bring your original licence{card ? ` and the card ending ${card.card_last4}` : ' and the card you paid with'}.</>}</p>
      </TripHero>

      {balanceDue > 0 && (
        <section className="pu-panel pu-panel--next" aria-labelledby="pt-bal" data-testid="renter-balance"><h2 className="pu-title" id="pt-bal">Balance due: {money(balanceDue, { cents: true })}</h2>
          <p>Your booking changed, or a charge was added: this is what is still owing. Pay it by card now (the price lines are below), or pay our team by e-Transfer or cash.</p>
          <form action={renterPayBalance}><input type="hidden" name="booking" value={b.id} /><button className="btn btn--primary" type="submit" data-testid="renter-pay-balance">Pay {money(balanceDue, { cents: true })}</button></form></section>
      )}
      <LicenceNotice number={b.booking_number} missing={licMissing} when={b.status === 'requested' ? 'request' : b.status === 'offered' ? 'offer' : 'pay'} />
      {waiting && (
        <section className="pu-panel pu-panel--next" aria-labelledby="pt-chg" data-testid="change-waiting"><h2 className="pu-title" id="pt-chg">{waiting.status === 'proposed' ? 'We suggest a change to your booking' : 'Your change is approved'}</h2>
          <p>{waiting.note ?? 'Review the new details and answer.'}</p>
          <p><Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number, 'change')}>Review and answer</Link></p>
        </section>
      )}
      {openQ.length > 0 && (
        <section className="pu-panel pu-panel--next" id="questions" aria-labelledby="pt-q"><h2 className="pu-title" id="pt-q">A question from our team</h2>
          {openQ.map((q) => <div key={q.id} className="stack"><p className="pt-note">{q.question}</p>{q.reply_by && <p className="small muted">Please answer by {when(q.reply_by)}.</p>}<InfoReply number={b.booking_number} requestId={q.id} /></div>)}
        </section>
      )}

      <div className="pt-split">
        <div className="pu-stack">
          {walk?.enabled && b.status !== 'closed' && (
            <PortalCard id="pt-walk" title="Your rental, step by step" testId="walk-card"
              action={<Link prefetch={false} className="btn btn--primary btn--sm" href={bookingPath(b.booking_number, 'walkthrough')} data-testid="walk-open">{(walk.done ?? 0) > 0 ? 'Continue' : 'Start the walkthrough'}</Link>}>
              <div className="pu-ringrow"><ProgressRing value={walk.done ?? 0} max={walk.total ?? 13} size={64} stroke={7} accent title={`${walk.done} of ${walk.total} steps done`} label={`${walk.done}/${walk.total}`} />
                <span className="pu-ringrow__label"><b>{STAGES.find((x) => x.key === walk.stage)?.title ?? 'Before pickup'}</b>Pickup, the walk-around of the car, the road rules and the return, one step at a time.</span></div>
            </PortalCard>
          )}
          <PortalCard id="pt-act" title="Manage your trip" testId="trip-actions">
            <QuickActions label="Trip actions">
              {(['requested', 'offered', 'confirmed', 'pending_payment'].includes(b.status) || (b.status === 'on_rent' && b.added_mode === 'in_progress')) && <QuickAction href={bookingPath(b.booking_number, 'verify')} icon="id" title={['requested', 'offered'].includes(b.status) ? 'Your licence' : 'Licence and coverage'} note="Photos, selfie and proof of coverage" />}
              {(b.status === 'on_rent' || b.status === 'confirmed') && <QuickAction href={bookingPath(b.booking_number, 'extend')} icon="extend" title={ext?.status === 'approved' ? 'Pay for the extension' : 'Extend'} note={ext?.status === 'requested' ? `Asked for ${when(ext.new_return_at)}` : 'Ask for more time with the car'} tone={ext?.status === 'approved' ? 'brand' : 'neutral'} testId="action-extend" />}
              {/* 0532: the car is back but the late notices keep coming: one tap stops them while staff check */}
              {/* 0545: the renter's own check-in at pickup, and own checkout (the same form as the late notices' link) */}
              {selfPickupOffered(b.status) && <QuickAction href={bookingPath(b.booking_number, 'pickup')} icon="camera" title="Check in yourself" note="Your photos, km and fuel at pickup" testId="action-self-pickup" />}
              {returnReportable(b.status, b.return_at) && <QuickAction href={bookingPath(b.booking_number, 'returned')} icon="key" title="Return the car yourself" note="Photos, km and fuel: done in one step" testId="action-returned" />}
              {b.status === 'confirmed' && <QuickAction href={bookingPath(b.booking_number, 'change')} icon="calendar" title="Ask to change dates" note="See the difference first" />}
              <QuickAction href="#messages" icon="chat" title="Message us" note={thread.length ? `${thread.length} ${thread.length === 1 ? 'message' : 'messages'} on this booking` : 'About this booking'} testId="action-message" />
              {phone && <QuickAction href={`tel:${tel}`} icon="phone" title={`Call us ${phone}`} note={s.opening_hours_text ?? 'We answer day and night'} testId="action-call" />}
              {['offered', 'pending_payment', 'confirmed', 'on_rent'].includes(b.status) && <QuickAction href={`${bookingPath(b.booking_number)}?ask=driver#messages`} icon="userPlus" title="Add a driver" note="Tell us who; they sign with their own link" testId="action-add-driver" />}
              {b.status === 'on_rent' && <QuickAction href={roadside ? `tel:${roadside}` : `${bookingPath(b.booking_number)}?ask=problem#messages`} icon="alert" tone="warn" title="Report a problem" note={roadside ? `Roadside help ${s.roadside_phone_display ?? roadside}` : 'A breakdown, damage or anything wrong'} testId="action-problem" />}
              {['on_rent', 'returned', 'closed'].includes(b.status) && <QuickAction href={bookingPath(b.booking_number, 'condition-report')} icon="camera" title="Photo report" note="Check-in and check-out, every photo" testId="renter-photo-report" />}
              <QuickAction href="#documents" icon="doc" title="Documents" note="Agreements, receipts, statements" testId="action-documents" />
              {b.status === 'closed' && b.booking_type !== 'owner' && <QuickAction href={bookingPath(b.booking_number, 'review')} icon="star" title="Review your rental" note="Stars and a few words" testId="review-link" />}
              {b.status === 'confirmed' && <QuickAction href={bookingPath(b.booking_number, 'cancel')} icon="x" title="Cancel booking" note="See what you get back first" />}
              {['closed', 'returned', 'cancelled', 'expired', 'declined'].includes(b.status) && <QuickAction href={b.slug ? `/cars/${b.slug}` : '/cars'} icon="repeat" title="Book again" note="Same car, new dates" testId="book-again" />}
            </QuickActions>
            {['requested', 'pending_payment'].includes(b.status) && <div><Withdraw number={b.booking_number} /></div>}
          </PortalCard>

          {accident && (
            <PortalCard id="pt-accident" title="Accident card" testId="renter-accident"
              action={<Link prefetch={false} className="btn btn--ghost btn--sm" href={bookingPath(b.booking_number, 'accident-card')} data-testid="accident-card-open">Print it</Link>}>
              {/* 1150: the digital incident card (also the printed card's QR code): coverage with proof, contract, drivers */}
              <p><Link prefetch={false} className="btn btn--primary btn--sm" href={incidentHref(b.booking_number)} data-testid="incident-card-open">Open the digital incident card</Link></p>
              {b.status === 'on_rent' && <AccidentReport booking={b.id} number={b.booking_number} phone={phone ?? null} />}
              <AccidentSummary d={accident} />
            </PortalCard>
          )}
          {report && report.km_in !== null && (
            <PortalCard id="pt-return" title="Your return: km and fuel" testId="return-receipt">
              <p className="small" data-testid="return-receipt-km">{report.km_driven !== null ? `${report.km_driven.toLocaleString('en-CA')} km driven, ${(report.km_allowance ?? 0).toLocaleString('en-CA')} km included${report.km_over > 0 ? `: ${report.km_over.toLocaleString('en-CA')} km over` : ''}.` : ''}
                {report.fuel_out_pct !== null && report.fuel_in_pct !== null ? ` ${report.electric ? 'Charge' : 'Fuel'}: ${report.fuel_short_pct > 0 ? `${Math.max(1, Math.round(report.fuel_short_pct / 12.5))}/8 lower than at pickup` : 'as at pickup'}.` : ''}</p>
              {readingCharges.length > 0
                ? <dl className="pt-dl pt-dl--money" data-testid="return-receipt-charges">{readingCharges.map((c) => <div key={c.key}><dt>{c.label}</dt><dd>{money(c.amount_cents + c.hst_cents, { cents: true })}</dd></div>)}</dl>
                : <p className="small muted">No extra km or fuel charge.</p>}
              <p><Link prefetch={false} className="link small" href={bookingPath(b.booking_number, 'condition-report')}>The photos, with both dashboard photos</Link></p>
            </PortalCard>
          )}
          {addons && (addons.items.length > 0 || addons.can_add) && <PortalAddons number={b.booking_number} data={addons} />}
          {b.drivers.length > 0 && <PortalCard id="pt-drivers" title="Drivers">
            <ul className="pt-list">{b.drivers.map((d) => (
              <li key={d.id} className="stack" style={{ gap: 'var(--s-2)' }}>
                <div className="pt-card__head"><b>{d.full_name}</b><span className="small muted">{d.role === 'renter' ? 'Renter' : 'Additional driver'}</span></div>
                <p className="small">{d.identity_verified_on ? 'Verified' : 'Not verified yet'}{d.role === 'additional' ? `. ${d.accepted_at ? 'Accepted the agreement' : `Waiting for ${d.full_name} to accept`}` : ''}</p>
                {(() => { const l = links.find((x) => x.booking_driver_id === d.id && !x.signed_at); return l && !d.accepted_at ? (
                  <DriverLink number={b.booking_number} signerId={l.signer_id} name={d.full_name} url={l.url} expired={l.expired} expiresText={when(l.expires_at)}
                    sentText={l.sent_at ? `Last emailed ${when(l.sent_at)}.` : null} />) : null; })()}
              </li>
            ))}</ul>
          </PortalCard>}
          {(b.change_requests.length > 0 || b.extensions.length > 0) && (
            <PortalCard id="pt-changes" title="Changes and extensions">
              {b.change_requests.map((c) => <div key={c.id} className="pt-msg"><p><b>Change:</b> {CHANGE[c.status] ?? c.status.replace(/_/g, ' ')}{c.decline_reason ? `. ${c.decline_reason}` : ''}</p><ChangeRequestActions number={b.booking_number} id={c.id} status={c.status} /></div>)}
              {b.extensions.map((e) => <div key={e.id} className="pt-msg"><p><b>Extension to {when(e.new_return_at)}:</b> {e.status}{e.total_cents ? `, ${money(e.total_cents, { cents: true })}` : ''}</p>{e.status === 'approved' && <Link prefetch={false} className="btn btn--primary btn--sm" href={bookingPath(b.booking_number, 'extend')}>Pay for the extension</Link>}</div>)}
            </PortalCard>
          )}
          {/* r35a: the less-used things, folded: a secondary contact (1302) and rideshare documents (1303) */}
          {(second || rideshareOpen) && <PortalCard id="pt-more" title="More" testId="trip-more">
            <Disclosure summary="More options for this trip" open={false} testId="trip-more-menu">
              <ul className="pt-list">
                {second && <li className="stack" data-testid="trip-secondary-contact"><b>Secondary contact</b>
                  <p className="small muted">{second.booking ? `For this trip: ${second.booking.name} (${second.booking.relationship}).` : second.profile ? `From your profile: ${second.profile.name} (${second.profile.relationship}). Change it for this trip below.` : 'Someone we may call if we cannot reach you during the trip. Optional.'}</p>
                  <SecondaryContactForm initial={second.booking ?? second.profile} booking={b.booking_number} testId="trip-secondary-form" /></li>}
                {rideshareOpen && <li><Link prefetch={false} className="link" href={bookingPath(b.booking_number, 'rideshare')} data-testid="trip-rideshare-link">Rideshare or delivery documents</Link>
                  <p className="small muted">For Uber, Lyft, DoorDash, Uber Eats, Instacart and others.</p></li>}
              </ul>
            </Disclosure>
          </PortalCard>}
          <Messages key={sp.ask ?? 'none'} number={b.booking_number} thread={thread} prefill={sp.ask ? ASK[sp.ask] : undefined} />
          <PortalCard id="documents" title="Documents" testId="booking-documents">
            {b.documents.length ? <DocumentList plain>{b.documents.filter((d) => !d.purged).map((d) => (
              <DocumentRow key={d.id} badge={BADGE[d.kind] ?? 'PDF'} external title={d.kind === 'rental_amendment' && d.title ? d.title : KIND[d.kind] ?? d.title} meta={when(d.created_at, false)} href={`/account/documents/${d.id}`} linkTestId={`doc-${d.kind}`} />
            ))}</DocumentList> : files.length ? null : <p className="muted small">Your agreement, receipts and statements appear here.</p>}
            {files.length > 0 && <DocumentList plain testId="generated-files">{files.map((f) => (
              <DocumentRow key={`${f.kind}:${f.key}`} external title={f.title} meta={when(f.at, false)} href={`/files/${f.kind}/${f.key}`} linkTestId={`file-${f.kind}`} />
            ))}</DocumentList>}
          </PortalCard>
        </div>
        <aside className="pt-split__aside pu-stack pu-money-first">
          <MoneyCard testId="money-summary"
            paid={<AnimatedNumber value={m.paidCents} format="cents" />}
            owing={owingCents > 0 ? <AnimatedNumber value={owingCents} format="cents" /> : null}
            parts={parts}
            pay={firstOwing?.sub ? { href: bookingPath(b.booking_number, firstOwing.sub), label: `${firstOwing.key === 'owe-booking' && !signed ? 'Sign and pay' : 'Pay'} ${money(firstOwing.cents, { cents: true })}` } : null}>
            <Disclosure summary="Price details" testId="price-details" open={['offered', 'pending_payment', 'requested'].includes(b.status)}>
              <PriceBreakdown lines={b.lines.filter((l) => l.stage === 'booking' && !laterLines.has(l.id))} hst={b.hst_at_booking_cents} total={b.renter_due_at_booking_cents} totalLabel={b.link_due ? 'Due now' : b.status === 'confirmed' || b.status === 'on_rent' || b.status === 'returned' || b.status === 'closed' ? 'Paid at booking' : 'Due at booking'} insurer={b.insurer_pays_cents || undefined} deposit={b.deposit_cents} />
            </Disclosure>
            {receipts.length > 0 && <div className="stack" data-testid="money-receipts"><p className="pu-eyebrow">Receipts</p><DocumentList plain>{receipts.map((r) => <DocumentRow key={r.key} external accent title={r.title} meta={when(r.at, false)} href={r.href} />)}</DocumentList></div>}
          </MoneyCard>
        </aside>
      </div>
    </>
  );
}
