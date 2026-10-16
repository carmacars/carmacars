import Link from 'next/link';
import { seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getSettings } from '@/lib/site';
import { when } from '@/features/agreement/model';
import { AWAITING_SIGNATURE, STATUS, awaitingSignature, bookingPath, carName, nextStep, progress } from '@/features/portal/status';
import { Back, Dl, PriceBreakdown, StatusBadge, placeText } from '@/features/portal/Blocks';
import { AddToCalendar } from '@/features/portal/AddToCalendar';
import { InfoReply } from '@/features/portal/InfoReply';
import { Messages, type Msg } from '@/features/portal/Messages';
import { rpc } from '@/lib/db/repo';
import { Withdraw } from '@/features/portal/Withdraw';
import { ChangeRequestActions } from '@/features/portal/SelfService';
import { myBooking } from '@/server/portal/data';
import { door } from '@/server/door';
import { bookingDriverLinks } from '@/server/portal/driver-links';
import { DriverLink } from '@/features/portal/DriverLink';

export const dynamic = 'force-dynamic';
export async function generateMetadata({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  return seoMeta({ title: `Booking ${n}`, path: `/account/bookings/${n}`, noindex: true, description: 'Your booking: status, next step, price, drivers and documents.' });
}

const CHANGE: Record<string, string> = { requested: 'asked for, waiting for our answer', proposed: 'suggested by us, waiting for your answer', approved: 'approved, waiting for your signature',
  applied: 'done', declined: 'declined', cancelled: 'withdrawn', expired: 'not accepted in time' };
const within = (iso: string, hours: number) => new Date(iso).getTime() - Date.now() < hours * 3600e3;

const KIND: Record<string, string> = { rental_amendment: 'Booking amendment', rental_agreement: 'Rental agreement', receipt: 'Receipt', renter_statement: 'Statement', condition_report: 'Condition Report', coverage_proof: 'Proof of coverage', id_front: 'Licence, front', id_back: 'Licence, back', face: 'Selfie' };

export default async function BookingPage({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { b, user } = await myBooking((await params).number);
  // receipts and statements, rendered on request and kept once final (migration 0032)
  const [files, thread] = await Promise.all([
    door<Array<{ kind: string; key: string; title: string; at: string }>>(user.id, 'ops_read', 'files', { for: 'booking', id: b.id }).catch(() => []),
    // the booking's messages, read as the signed-in renter (migration 0033)
    rpc('my_booking_messages', { p_number: b.booking_number }, { role: 'authenticated', userId: user.id }).then((x) => (x ?? []) as unknown as Msg[]).catch(() => [] as Msg[])]);
  const [sp, s] = await Promise.all([searchParams, getSettings()]);
  const step = nextStep(b);
  const card = b.payments.find((p) => p.purpose === 'booking_total' && p.card_last4);
  const openQ = b.info_requests.filter((q) => q.status === 'open');
  // each additional driver's own signing link (migration 0040: versioned, expiring, renewed here)
  const links = b.agreement && b.drivers.some((d) => d.role === 'additional') ? await bookingDriverLinks(b.id, user.id) : [];
  const waiting = b.change_requests.find((c) => ['proposed', 'approved'].includes(c.status));
  const live = ['confirmed', 'on_rent'].includes(b.status);
  const pickupSoon = live && within(b.pickup_at, 24);
  const ext = b.extensions[b.extensions.length - 1];
  const phone = s.phone_display ?? s.phone;
  return (
    <>
      <Back href="/account">Your trips</Back>
      {sp.changed && <div className="pt-ok" role="status" data-testid="changed-panel"><h2 className="d3">Booking updated</h2><p>Your booking has the new details. The signed amendment is under Documents, and we emailed you a copy.</p></div>}
      {sp.declined && <div className="pt-ok" role="status" data-testid="declined-panel"><h2 className="d3">Change declined</h2><p>Your booking stays as it was. We let our team know.</p></div>}
      {sp.paid && b.status === 'confirmed' && <div className="pt-ok" role="status" data-testid="paid-panel"><h2 className="d3">Booking confirmed</h2><p>Your card was charged {money(card?.amount_cents ?? b.renter_due_at_booking_cents, { cents: true })} and the car is reserved for you. Your signed agreement and receipt are below.</p></div>}
      <header className="stack">
        <div className="row" style={{ gap: 'var(--s-2)' }}><StatusBadge s={b.status} awaiting={awaitingSignature(b)} /><span className="small muted" data-testid="booking-number">{b.booking_number}</span></div>
        <h1 className="d2">{carName(b)}</h1>
        <p className="lead">{when(b.pickup_at)} to {when(b.return_at)}</p>
        <p className="muted">{awaitingSignature(b) ? AWAITING_SIGNATURE.blurb : STATUS[b.status].blurb}</p>
        {live && <div><AddToCalendar number={b.booking_number} car={carName(b)} pickup={b.pickup_at} ret={b.return_at} place={b.pickup_place ?? 'CarmaCars'} /></div>}
      </header>
      <div className="pt-split">
        <div className="stack-lg">
          {step.href && step.href !== bookingPath(b.booking_number) && (
            <section className="pt-card pt-card--next" aria-labelledby="pt-step"><h2 className="d4" id="pt-step">{step.title}</h2><p>{step.note}</p><p><Link prefetch={false} className="btn btn--primary" href={step.href}>{step.cta}</Link></p></section>
          )}
          {waiting && (
            <section className="pt-card pt-card--next" aria-labelledby="pt-chg" data-testid="change-waiting"><h2 className="d4" id="pt-chg">{waiting.status === 'proposed' ? 'We suggest a change to your booking' : 'Your change is approved'}</h2>
              <p>{waiting.note ?? 'Review the new details and answer.'}</p>
              <p><Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number, 'change')}>Review and answer</Link></p>
            </section>
          )}
          {openQ.length > 0 && (
            <section className="pt-card pt-card--next" id="questions" aria-labelledby="pt-q"><h2 className="d4" id="pt-q">A question from our team</h2>
              {openQ.map((q) => <div key={q.id} className="stack"><p className="pt-note">{q.question}</p>{q.reply_by && <p className="small muted">Please answer by {when(q.reply_by)}.</p>}<InfoReply number={b.booking_number} requestId={q.id} /></div>)}
            </section>
          )}
          <section className="pt-card" aria-labelledby="pt-prog"><h2 className="d4" id="pt-prog">Progress</h2>
            <ol className="pt-steps">{progress(b).map((p) => <li key={p.label} className={p.done ? 'is-done' : ''}>{p.href && !p.done ? <Link prefetch={false} className="link" href={p.href}>{p.label}</Link> : p.label}<span className="vh">{p.done ? ', done' : ', to do'}</span></li>)}</ol>
          </section>
          <section className="pt-card" aria-labelledby="pt-trip"><h2 className="d4" id="pt-trip">{pickupSoon ? 'Pickup details' : 'Trip'}</h2>
            <Dl rows={[
              ['Pickup', `${when(b.pickup_at)}, ${placeText(b.pickup_place, b.pickup_method, true)}`],
              ['Return', `${when(b.return_at)}, ${placeText(b.return_place, b.return_method, false)}`],
              ['Length', `${b.billable_days} days`],
              ['Kilometres', b.km_allowance_total ? `${b.km_allowance_total} km included, then ${money(b.overage_cents_per_km, { cents: true })} per km` : ''],
              ['Deposit at pickup', money(b.deposit_cents)],
              ['Bring', live ? `Your original licence${card ? ` and the card ending ${card.card_last4}` : ' and the card you paid with'}` : '']
            ]} />
            {live && phone && <p><a className="btn btn--ghost btn--sm" href={`tel:${s.phone ?? phone}`}>Call us {phone}</a></p>}
          </section>
          <section className="pt-card" aria-labelledby="pt-drivers"><h2 className="d4" id="pt-drivers">Drivers</h2>
            <ul className="pt-list">{b.drivers.map((d) => (
              <li key={d.id} className="stack" style={{ gap: 'var(--s-2)' }}>
                <div className="pt-card__head"><b>{d.full_name}</b><span className="small muted">{d.role === 'renter' ? 'Renter' : 'Additional driver'}</span></div>
                <p className="small">{d.identity_verified_on ? 'Verified' : 'Not verified yet'}{d.role === 'additional' ? `. ${d.accepted_at ? 'Accepted the agreement' : `Waiting for ${d.full_name} to accept`}` : ''}</p>
                {(() => { const l = links.find((x) => x.booking_driver_id === d.id && !x.signed_at); return l && !d.accepted_at ? (
                  <DriverLink number={b.booking_number} signerId={l.signer_id} name={d.full_name} url={l.url} expired={l.expired} expiresText={when(l.expires_at)}
                    sentText={l.sent_at ? `Last emailed ${when(l.sent_at)}.` : null} />) : null; })()}
              </li>
            ))}</ul>
          </section>
          {(b.change_requests.length > 0 || b.extensions.length > 0) && (
            <section className="pt-card" aria-labelledby="pt-changes"><h2 className="d4" id="pt-changes">Changes and extensions</h2>
              {b.change_requests.map((c) => <div key={c.id} className="pt-msg"><p><b>Change:</b> {CHANGE[c.status] ?? c.status.replace(/_/g, ' ')}{c.decline_reason ? `. ${c.decline_reason}` : ''}</p><ChangeRequestActions number={b.booking_number} id={c.id} status={c.status} /></div>)}
              {b.extensions.map((e) => <div key={e.id} className="pt-msg"><p><b>Extension to {when(e.new_return_at)}:</b> {e.status}{e.total_cents ? `, ${money(e.total_cents, { cents: true })}` : ''}</p>{e.status === 'approved' && <Link prefetch={false} className="btn btn--primary btn--sm" href={bookingPath(b.booking_number, 'extend')}>Pay for the extension</Link>}</div>)}
            </section>
          )}
          <Messages number={b.booking_number} thread={thread} />
          <section className="pt-card" aria-labelledby="pt-docs"><h2 className="d4" id="pt-docs">Documents</h2>
            {b.documents.length ? <ul className="pt-list">{b.documents.filter((d) => !d.purged).map((d) => (
              <li key={d.id} className="pt-card__head"><span>{d.kind === 'rental_amendment' && d.title ? d.title : KIND[d.kind] ?? d.title}<span className="xs muted"> · {when(d.created_at, false)}</span></span><a className="link" href={`/account/documents/${d.id}`} data-testid={`doc-${d.kind}`}>Download</a></li>
            ))}</ul> : files.length ? null : <p className="muted small">Your agreement, receipts and statements appear here.</p>}
            {files.length > 0 && <ul className="pt-list" data-testid="generated-files">{files.map((f) => (
              <li key={`${f.kind}:${f.key}`} className="pt-card__head"><span>{f.title}<span className="xs muted"> · {when(f.at, false)}</span></span><a className="link" href={`/files/${f.kind}/${f.key}`} data-testid={`file-${f.kind}`}>Download PDF</a></li>
            ))}</ul>}
          </section>
        </div>
        <aside className="pt-split__aside stack-lg">
          <section className="pt-card" aria-labelledby="pt-price"><h2 className="d4" id="pt-price">Price</h2>
            <PriceBreakdown lines={b.lines.filter((l) => l.stage === 'booking')} hst={b.hst_at_booking_cents} total={b.renter_due_at_booking_cents} totalLabel={b.status === 'confirmed' || b.status === 'on_rent' || b.status === 'returned' || b.status === 'closed' ? 'Paid at booking' : 'Due at booking'} insurer={b.insurer_pays_cents || undefined} deposit={b.deposit_cents} />
            {b.payments.length > 0 && <Dl rows={b.payments.map((p) => [`${p.purpose.replace(/_/g, ' ')} (${p.status})`, `${money(p.amount_cents, { cents: true })}${p.card_last4 ? `, card ending ${p.card_last4}` : ''}`])} />}
          </section>
          <section className="pt-card" aria-labelledby="pt-act"><h2 className="d4" id="pt-act">Need something else?</h2>
            <div className="pt-actions">
              {b.status === 'offered' && <Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number, 'offer')}>Review the offer</Link>}
              {b.status === 'pending_payment' && <Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number, b.agreement?.renter_signed_at ? 'pay' : 'sign')}>{b.agreement?.renter_signed_at ? 'Pay now' : 'Sign the agreement'}</Link>}
              {['confirmed', 'pending_payment'].includes(b.status) && <Link prefetch={false} className="btn btn--ghost" href={bookingPath(b.booking_number, 'verify')}>Licence and coverage</Link>}
              {b.status === 'confirmed' && <Link prefetch={false} className="btn btn--ghost" href={bookingPath(b.booking_number, 'change')}>Ask to change dates</Link>}
              {b.status === 'confirmed' && <Link prefetch={false} className="btn btn--ghost" href={bookingPath(b.booking_number, 'cancel')}>Cancel booking</Link>}
              {(b.status === 'on_rent' || b.status === 'confirmed') && <Link prefetch={false} className="btn btn--ghost" href={bookingPath(b.booking_number, 'extend')}>{ext?.status === 'approved' ? 'Pay for the extension' : 'Extend'}</Link>}
              {['requested', 'pending_payment'].includes(b.status) && <Withdraw number={b.booking_number} />}
              {b.status === 'closed' && b.booking_type !== 'owner' && <Link prefetch={false} className="btn btn--ghost" href={bookingPath(b.booking_number, 'review')} data-testid="review-link">Review your rental</Link>}
              {phone && <a className="btn btn--quiet" href={`tel:${s.phone ?? phone}`}>Call us {phone}</a>}
            </div>
          </section>
        </aside>
      </div>
    </>
  );
}
