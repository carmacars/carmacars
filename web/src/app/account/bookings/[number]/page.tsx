import Link from 'next/link';
import { seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getFleet, getSettings } from '@/lib/site';
import { when } from '@/features/agreement/model';
import { AWAITING_SIGNATURE, STATUS, awaitingSignature, bookingPath, nextStep, progress } from '@/features/portal/status';
import { Back, PriceBreakdown } from '@/features/portal/Blocks';
import { AddToCalendar } from '@/features/portal/AddToCalendar';
import { InfoReply } from '@/features/portal/InfoReply';
import { Messages, type Msg } from '@/features/portal/Messages';
import { rpc } from '@/lib/db/repo';
import { Withdraw } from '@/features/portal/Withdraw';
import { ChangeRequestActions } from '@/features/portal/SelfService';
import { myBooking, myTripPhotos } from '@/server/portal/data';
import { LicenceNotice, licenceState, renterMissing } from '@/features/portal/LicenceNotice';
import { door } from '@/server/door';
import { bookingDriverLinks } from '@/server/portal/driver-links';
import { DriverLink } from '@/features/portal/DriverLink';
import { PortalAddons, type MyAddons } from '@/features/addons/PortalAddons';
import type { HandoverReportData } from '@/features/handover/types';
import { ActionGrid, ActionTile, CountUp, Disclosure, DocumentList, DocumentRow, MoneySummary, PortalCard, ProgressRing, Timeline, TimelineItem, type MoneyPart } from '@/components/portal-ui';
import { NextStepBox, TripHero, tripPhoto } from '@/features/portal/trip';
import { moneyParts } from '@/features/portal/trip-model';

export const dynamic = 'force-dynamic';
export async function generateMetadata({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  return seoMeta({ title: `Booking ${n}`, path: `/account/bookings/${n}`, noindex: true, description: 'Your booking: status, next step, price, drivers and documents.' });
}

const CHANGE: Record<string, string> = { requested: 'asked for, waiting for our answer', proposed: 'suggested by us, waiting for your answer', approved: 'approved, waiting for your signature',
  applied: 'done', declined: 'declined', cancelled: 'withdrawn', expired: 'not accepted in time' };

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
  const [sp, s, addons, report] = await Promise.all([searchParams, getSettings(),
    // the add-ons on the booking and what may still be added (0066)
    b.booking_type === 'owner' ? Promise.resolve(null) : rpc('server_my_booking_addons', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as MyAddons).catch(() => null),
    // the kilometres driven, once the car is back (the photo report's reading, 0130)
    b.checked_in_at ? rpc('server_renter_handover_report', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).then((x) => x as unknown as HandoverReportData | null).catch(() => null) : Promise.resolve(null)]);
  const laterLines = new Set((addons?.items ?? []).filter((a) => a.after_booking).map((a) => a.line_item_id).filter(Boolean));
  const step = nextStep(b);
  // the licence first (0130): from the request until it is on file
  const licMissing = ['requested', 'offered', 'pending_payment'].includes(b.status) ? renterMissing(await licenceState(b.id, user.id)) : null;
  const openQ = b.info_requests.filter((q) => q.status === 'open');
  // each additional driver's own signing link (migration 0040: versioned, expiring, renewed here)
  const links = b.agreement && b.drivers.some((d) => d.role === 'additional') ? await bookingDriverLinks(b.id, user.id) : [];
  const waiting = b.change_requests.find((c) => ['proposed', 'approved'].includes(c.status));
  const live = ['confirmed', 'on_rent'].includes(b.status);
  const ext = b.extensions[b.extensions.length - 1];
  const phone = s.phone_display ?? s.phone;
  const tel = s.phone ?? phone;
  const roadside = s.roadside_phone ?? null;
  const card = b.payments.find((p) => p.purpose === 'booking_total' && p.card_last4);
  const photo = tripPhoto(photos, b, fleet.find((c) => c.slug === b.slug)?.cover ?? null);
  const signed = !!b.agreement?.renter_signed_at;
  const actionable = !!step.href && step.href !== bookingPath(b.booking_number);
  // the hero's next step names the action the tests and the guide know (live-sign, live-pay)
  const stepId = b.status === 'on_rent' && b.added_live && !signed ? 'live-sign' : b.link_due && signed ? 'live-pay' : 'booking-next-step-cta';
  const steps = progress(b);
  const done = steps.filter((p) => p.done).length;
  const firstTodo = steps.findIndex((p) => !p.done);

  // money: what is paid and what is open, by part, as the database stored it
  const m = moneyParts({ status: b.status, renter_due_at_booking_cents: b.renter_due_at_booking_cents, deposit_cents: b.deposit_cents, link_due: b.link_due, signed,
    payments: b.payments, refunds: b.refunds, extensions: b.extensions, addons: addons?.items ?? [], changes: b.change_requests });
  const parts: MoneyPart[] = m.parts.map((p) => ({ key: p.key, label: p.label, amount: money(p.cents, { cents: true }), state: p.state, note: p.note,
    href: p.sub ? bookingPath(b.booking_number, p.sub) : undefined, cta: p.state === 'owing' || p.state === 'info' ? p.cta : undefined, testId: `money-${p.key}` }));
  const firstOwing = m.parts.find((p) => p.state === 'owing');
  const receipts = [...b.documents.filter((d) => !d.purged && ['receipt', 'renter_statement'].includes(d.kind)).map((d) => ({ key: d.id, kind: d.kind, title: KIND[d.kind] ?? d.title ?? 'Receipt', at: d.created_at, href: `/account/documents/${d.id}` })),
    ...files.filter((f) => ['receipt', 'renter_statement', 'statement'].includes(f.kind)).map((f) => ({ key: `${f.kind}:${f.key}`, kind: f.kind, title: f.title, at: f.at, href: `/files/${f.kind}/${f.key}` }))];

  const next = actionable
    ? <NextStepBox step={step} testId="booking-next-step" ctaTestId={stepId} calm={!step.urgent} />
    : <NextStepBox step={{ ...step, href: undefined }} calm kicker={live ? 'All set' : STATUS[b.status].label} testId="booking-next-step"
        extra={live ? <div className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}><AddToCalendar number={b.booking_number} car={`${b.vehicle_year} ${b.vehicle_make} ${b.vehicle_model}`} pickup={b.pickup_at} ret={b.return_at} place={b.pickup_place ?? 'CarmaCars'} />{phone && <a className="btn btn--quiet btn--sm" href={`tel:${tel}`}>Call us {phone}</a>}</div> : null} />;

  return (
    <>
      <Back href="/account">Your trips</Back>
      {sp.changed && <div className="pt-ok" role="status" data-testid="changed-panel"><h2 className="d3">Booking updated</h2><p>Your booking has the new details. The signed amendment is under Documents, and we emailed you a copy.</p></div>}
      {sp.declined && <div className="pt-ok" role="status" data-testid="declined-panel"><h2 className="d3">Change declined</h2><p>Your booking stays as it was. We let our team know.</p></div>}
      {sp.paid && b.status === 'on_rent' && b.added_live && !b.link_due && <div className="pt-ok" role="status" data-testid="paid-live-panel"><h2 className="d3">Paid, thank you</h2><p>Your card was charged {money(b.renter_due_at_booking_cents, { cents: true })} for your rental. Your signed agreement and receipt are below.</p></div>}
      {sp.paid && b.status === 'confirmed' && <div className="pt-ok" role="status" data-testid="paid-panel"><h2 className="d3">Booking confirmed</h2><p>Your card was charged {money(card?.amount_cents ?? b.renter_due_at_booking_cents, { cents: true })} and the car is reserved for you. Your signed agreement and receipt are below.</p></div>}

      <TripHero b={b} photo={photo} settings={s} next={next} kmDriven={report?.km_driven ?? null} prepaidFuel={(addons?.items ?? []).some((a) => a.prepaid_fuel)}>
        <p className="small muted" data-testid="status-blurb">{awaitingSignature(b) ? AWAITING_SIGNATURE.blurb : STATUS[b.status].blurb}
          {b.status === 'confirmed' && <> Bring your original licence{card ? ` and the card ending ${card.card_last4}` : ' and the card you paid with'}.</>}</p>
      </TripHero>

      <LicenceNotice number={b.booking_number} missing={licMissing} when={b.status === 'requested' ? 'request' : b.status === 'offered' ? 'offer' : 'pay'} />
      {waiting && (
        <section className="pu-card pu-card--next" aria-labelledby="pt-chg" data-testid="change-waiting"><h2 className="pu-card__title" id="pt-chg">{waiting.status === 'proposed' ? 'We suggest a change to your booking' : 'Your change is approved'}</h2>
          <p>{waiting.note ?? 'Review the new details and answer.'}</p>
          <p><Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number, 'change')}>Review and answer</Link></p>
        </section>
      )}
      {openQ.length > 0 && (
        <section className="pu-card pu-card--next" id="questions" aria-labelledby="pt-q"><h2 className="pu-card__title" id="pt-q">A question from our team</h2>
          {openQ.map((q) => <div key={q.id} className="stack"><p className="pt-note">{q.question}</p>{q.reply_by && <p className="small muted">Please answer by {when(q.reply_by)}.</p>}<InfoReply number={b.booking_number} requestId={q.id} /></div>)}
        </section>
      )}

      <div className="pt-split">
        <div className="pu-stack">
          <PortalCard id="pt-act" title="Manage your trip" testId="trip-actions">
            <ActionGrid label="Trip actions">
              {(['requested', 'offered', 'confirmed', 'pending_payment'].includes(b.status) || (b.status === 'on_rent' && b.added_mode === 'in_progress')) && <ActionTile href={bookingPath(b.booking_number, 'verify')} icon="id" title={['requested', 'offered'].includes(b.status) ? 'Your licence' : 'Licence and coverage'} note="Photos, selfie and proof of coverage" />}
              {(b.status === 'on_rent' || b.status === 'confirmed') && <ActionTile href={bookingPath(b.booking_number, 'extend')} icon="extend" title={ext?.status === 'approved' ? 'Pay for the extension' : 'Extend'} note={ext?.status === 'requested' ? `Asked for ${when(ext.new_return_at)}` : 'Ask for more time with the car'} tone={ext?.status === 'approved' ? 'brand' : 'neutral'} />}
              {b.status === 'confirmed' && <ActionTile href={bookingPath(b.booking_number, 'change')} icon="calendar" title="Ask to change dates" note="See the difference first" />}
              <ActionTile href="#messages" icon="chat" title="Message us" note={thread.length ? `${thread.length} ${thread.length === 1 ? 'message' : 'messages'} on this booking` : 'About this booking'} testId="action-message" />
              {phone && <ActionTile href={`tel:${tel}`} icon="phone" title={`Call us ${phone}`} note={s.opening_hours_text ?? 'We answer day and night'} testId="action-call" />}
              {['offered', 'pending_payment', 'confirmed', 'on_rent'].includes(b.status) && <ActionTile href={`${bookingPath(b.booking_number)}?ask=driver#messages`} icon="userPlus" title="Add a driver" note="Tell us who; they sign with their own link" testId="action-add-driver" />}
              {b.status === 'on_rent' && <ActionTile href={roadside ? `tel:${roadside}` : `${bookingPath(b.booking_number)}?ask=problem#messages`} icon="alert" tone="warn" title="Report a problem" note={roadside ? `Roadside help ${s.roadside_phone_display ?? roadside}` : 'A breakdown, damage or anything wrong'} testId="action-problem" />}
              {['on_rent', 'returned', 'closed'].includes(b.status) && <ActionTile href={bookingPath(b.booking_number, 'condition-report')} icon="camera" title="Photo report" note="Check-out and check-in, every photo" testId="renter-photo-report" />}
              <ActionTile href="#documents" icon="doc" title="Documents" note="Agreements, receipts, statements" testId="action-documents" />
              {b.status === 'closed' && b.booking_type !== 'owner' && <ActionTile href={bookingPath(b.booking_number, 'review')} icon="star" title="Review your rental" note="Stars and a few words" testId="review-link" />}
              {b.status === 'confirmed' && <ActionTile href={bookingPath(b.booking_number, 'cancel')} icon="x" title="Cancel booking" note="See what you get back first" />}
              {['closed', 'returned', 'cancelled', 'expired', 'declined'].includes(b.status) && <ActionTile href={b.slug ? `/cars/${b.slug}` : '/cars'} icon="repeat" title="Book again" note="Same car, new dates" testId="book-again" />}
            </ActionGrid>
            {['requested', 'pending_payment'].includes(b.status) && <div><Withdraw number={b.booking_number} /></div>}
          </PortalCard>

          <PortalCard id="pt-prog" title="Progress" testId="trip-progress">
            <ProgressRing value={done} total={steps.length} label={<><b>{firstTodo >= 0 ? steps[firstTodo]!.label : 'All done'}</b>{firstTodo >= 0 ? 'is next' : 'Every step is complete'}</>} testId="progress-ring" />
            <Disclosure summary="Every step" open={false} testId="progress-steps">
              <Timeline label="Booking progress">{steps.map((p, i) => <TimelineItem key={p.label} title={p.label} href={p.href} state={p.done ? 'done' : i === firstTodo ? 'current' : 'todo'} />)}</Timeline>
            </Disclosure>
          </PortalCard>

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
          <Messages key={sp.ask ?? 'none'} number={b.booking_number} thread={thread} prefill={sp.ask ? ASK[sp.ask] : undefined} />
          <PortalCard id="documents" title="Documents" testId="booking-documents">
            {b.documents.length ? <DocumentList>{b.documents.filter((d) => !d.purged).map((d) => (
              <DocumentRow key={d.id} kind={d.kind} title={d.kind === 'rental_amendment' && d.title ? d.title : KIND[d.kind] ?? d.title} meta={when(d.created_at, false)} href={`/account/documents/${d.id}`} testId={`doc-${d.kind}`} />
            ))}</DocumentList> : files.length ? null : <p className="muted small">Your agreement, receipts and statements appear here.</p>}
            {files.length > 0 && <DocumentList testId="generated-files">{files.map((f) => (
              <DocumentRow key={`${f.kind}:${f.key}`} kind={f.kind} title={f.title} meta={when(f.at, false)} href={`/files/${f.kind}/${f.key}`} action="Download PDF" testId={`file-${f.kind}`} />
            ))}</DocumentList>}
          </PortalCard>
        </div>
        <aside className="pt-split__aside pu-stack pu-money-first">
          <MoneySummary testId="money-summary"
            paid={<CountUp cents={m.paidCents} text={money(m.paidCents, { cents: true })} />}
            owing={m.owingCents > 0 ? <CountUp cents={m.owingCents} text={money(m.owingCents, { cents: true })} /> : null}
            parts={parts}
            pay={firstOwing?.sub ? { href: bookingPath(b.booking_number, firstOwing.sub), label: `${firstOwing.sub === 'sign' ? 'Sign, then pay' : 'Pay'} ${money(firstOwing.cents, { cents: true })}` } : null}>
            <Disclosure summary="Price details" testId="price-details" open={['offered', 'pending_payment', 'requested'].includes(b.status)}>
              <PriceBreakdown lines={b.lines.filter((l) => l.stage === 'booking' && !laterLines.has(l.id))} hst={b.hst_at_booking_cents} total={b.renter_due_at_booking_cents} totalLabel={b.link_due ? 'Due now' : b.status === 'confirmed' || b.status === 'on_rent' || b.status === 'returned' || b.status === 'closed' ? 'Paid at booking' : 'Due at booking'} insurer={b.insurer_pays_cents || undefined} deposit={b.deposit_cents} />
            </Disclosure>
            {receipts.length > 0 && <div className="stack" data-testid="money-receipts"><p className="pu-eyebrow">Receipts</p><DocumentList>{receipts.map((r) => <DocumentRow key={r.key} kind={r.kind} title={r.title} meta={when(r.at, false)} href={r.href} />)}</DocumentList></div>}
          </MoneySummary>
        </aside>
      </div>
    </>
  );
}
