import Link from '@/components/Link';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { Card } from '@/features/admin/ui';
import { Chip } from '@/features/bookings-now/parts';
import { INSTANT_REPEAT, OFFER_STATUS, OWNER_TRIP, PROOF_TONE, lineWords, priceChange, revertHref, type CoverageCard, type History, type OfferVersion, type Price } from './model';

// r35a (1300): on the booking page of an Admin, customer service, Sales and Fleet: the coverage the renter chose with its
// proof status (at the top), the request exactly as the renter sent it, and every offer version with its price, who sent it
// and when, each old one with "Revert to this offer" (it loads that version into the review as a new offer to send).
const $ = (c: number | null | undefined) => (c === null || c === undefined ? '' : money(c, { cents: true }));
const at = (iso: string | null | undefined) => (iso ? when(iso) : '');

/** The owner's own trip or an instant booking, as a chip beside the booking's title and on the rows. */
export function BookingKindChips({ ownerTrip, instant, testId = 'booking-kind' }: { ownerTrip: boolean; instant?: boolean; testId?: string }) {
  if (!ownerTrip && !instant) return null;
  return (
    <span className="row" style={{ gap: 'var(--s-2)', display: 'inline-flex' }} data-testid={testId}>
      {ownerTrip && <Chip tone="amber" testId={`${testId}-owner`}>{OWNER_TRIP}</Chip>}
      {instant && <Chip tone="ok" testId={`${testId}-instant`}>{INSTANT_REPEAT}</Chip>}
    </span>
  );
}

/** The coverage the renter chose and its proof, prominent at the top of the request or booking. */
export function CoverageStrip({ c, ownerTrip }: { c: CoverageCard | null; ownerTrip: boolean }) {
  if (!c) return null;
  const changed = c.requested_option !== null && c.option !== null && c.requested_option !== c.option;
  return (
    <section className={`alert ${PROOF_TONE[c.proof] === 'ok' ? 'alert--ok' : PROOF_TONE[c.proof] === 'red' ? 'alert--warn' : 'alert--info'}`} aria-label="Coverage" data-testid="coverage-strip">
      <span className="alert__title">Coverage: {ownerTrip ? 'not needed (owner\'s own trip)' : c.short ?? 'not chosen yet'}</span>
      <span>
        <Chip tone={PROOF_TONE[c.proof]} testId="coverage-proof">{c.proof_words}</Chip>
        {c.detail ? <> · {c.detail}</> : null}
        {changed && <> · The renter asked for option {c.requested_option}; it is option {c.option} now.</>}
      </span>
    </section>
  );
}

function PriceList({ p, testId }: { p: Pick<Price, 'lines' | 'hst_cents' | 'total_cents'> & { renter_due_cents?: number; deposit_cents?: number }; testId?: string }) {
  return (
    <dl className="pt-dl pt-dl--money small" data-testid={testId}>
      {p.lines.map((l, i) => <div key={`${l.charge_type}${i}`}><dt>{lineWords(l)}</dt><dd>{$(l.amount_cents)}</dd></div>)}
      <div><dt>HST</dt><dd>{$(p.hst_cents)}</dd></div>
      <div><dt><b>Total</b></dt><dd><b>{$(p.total_cents)}</b></dd></div>
      {p.renter_due_cents !== undefined && p.renter_due_cents !== p.total_cents && <div><dt>The renter pays</dt><dd>{$(p.renter_due_cents)}</dd></div>}
      {p.deposit_cents ? <div><dt>Deposit at pickup</dt><dd>{$(p.deposit_cents)}</dd></div> : null}
    </dl>
  );
}

function OfferRow({ o, prev, base, mayRevert }: { o: OfferVersion; prev: OfferVersion | null; base: string; mayRevert: boolean }) {
  const change = priceChange(prev, o, $);
  return (
    <li className="pt-card stack" data-testid={`offer-v${o.version}`} style={{ gap: 'var(--s-2)' }}>
      <div className="pt-card__head">
        <b>Version {o.version}{o.current ? ' (current)' : ''}</b>
        <Chip tone={o.status === 'approved' ? 'ok' : o.status === 'sent' ? 'amber' : 'quiet'}>{OFFER_STATUS[o.status] ?? o.status.replace(/_/g, ' ')}</Chip>
      </div>
      <p className="small">Sent {at(o.sent_at)} by {o.sent_by_name}{o.responded_at ? ` · answered ${at(o.responded_at)}` : ''} · open until {at(o.expires_at)}</p>
      <p className="small">{o.vehicle_name} · {at(o.pickup_at)} to {at(o.return_at)} · {o.billable_days} day{o.billable_days === 1 ? '' : 's'}{o.km_allowance_per_day ? ` · ${o.km_allowance_per_day} km a day` : ''}{o.promo_code ? ` · code ${o.promo_code}` : ''}</p>
      {change && <p className="small muted">{change} from version {prev!.version}</p>}
      {o.message && <p className="small"><span className="muted">Message:</span> {o.message}</p>}
      <details className="oc-disclose"><summary>Price breakdown, {$(o.total_cents)}</summary>
        <PriceList p={{ lines: o.lines, hst_cents: o.hst_cents, total_cents: o.total_cents, renter_due_cents: o.renter_due_cents, deposit_cents: o.deposit_cents }} testId={`offer-v${o.version}-price`} />
      </details>
      {mayRevert && !o.current && <p><Link prefetch={false} className="btn btn--ghost btn--sm" href={revertHref(base, o.version)} data-testid={`offer-revert-${o.version}`}>Revert to this offer</Link></p>}
    </li>
  );
}

/** The request as sent and the offer history. */
export function RequestHistory({ h, base }: { h: History; base: string }) {
  const o = h.original;
  const ordered = [...h.offers].sort((a, z) => a.version - z.version);
  const prevOf = (v: number) => ordered.filter((x) => x.version < v).pop() ?? null;
  const mayRevert = h.may_revert && ['requested', 'offered', 'pending_payment'].includes(h.status);
  return (
    <div className="ad-cols ad-cols--2" data-testid="request-history">
      <Card title="Original request, as the renter sent it" testId="original-request">
        {!o ? <p className="small muted">{h.made_by_staff ? 'Made by staff: there was no request from the renter.' : 'No request on this booking.'}</p> : (
          <div className="stack">
            {o.source === 'backfill' && <p className="small muted" data-testid="original-backfill">This request came in before its first version was kept: the dates, choices and note are the request&apos;s{o.price ? '' : '; the car and the price had already changed, so they are not shown'}.</p>}
            <dl className="pt-dl small">
              <div><dt>Sent</dt><dd>{at(o.requested_at ?? o.captured_at)}</dd></div>
              {o.vehicle_name && <div><dt>Car</dt><dd>{o.vehicle_name}</dd></div>}
              <div><dt>Dates</dt><dd>{at(o.pickup_at)} to {at(o.return_at)}{o.billable_days ? ` (${o.billable_days} day${o.billable_days === 1 ? '' : 's'})` : ''}</dd></div>
              {(o.pickup_place || o.return_place) && <div><dt>Places</dt><dd>{o.pickup_place ?? 'our location'} · {o.return_place ?? 'our location'}</dd></div>}
              <div><dt>Coverage</dt><dd data-testid="original-coverage">{h.owner_trip ? 'Not needed (owner\'s own trip)' : o.coverage_label ?? 'not chosen'}</dd></div>
              <div><dt>Add-ons</dt><dd>{o.addons.length ? o.addons.map((a) => `${a.name}${a.quantity > 1 ? ` x${a.quantity}` : ''}`).join(', ') : 'none'}{o.extras?.baby_seats ? ` · ${o.extras.baby_seats} baby seat${o.extras.baby_seats === 1 ? '' : 's'}` : ''}{o.extras?.winter_tire ? ' · winter tires' : ''}</dd></div>
              {o.drivers > 0 && <div><dt>Drivers named</dt><dd>{o.drivers}</dd></div>}
              {o.promo_code && <div><dt>Promo code</dt><dd>{o.promo_code}</dd></div>}
              <div><dt>Note</dt><dd>{o.note || 'none'}</dd></div>
            </dl>
            {o.price ? <><p className="pt-kicker">Price shown to the renter</p><PriceList p={o.price} testId="original-price" /></> : null}
          </div>)}
      </Card>
      <Card title="Offer history" testId="offer-history" aside={<span className="small muted">{h.offers.length} version{h.offers.length === 1 ? '' : 's'}</span>}>
        {h.offers.length === 0 ? <p className="small muted">No offer sent yet.</p>
          : <ol className="stack" style={{ listStyle: 'none', padding: 0 }}>{[...ordered].reverse().map((x) => <OfferRow key={x.version} o={x} prev={prevOf(x.version)} base={base} mayRevert={mayRevert} />)}</ol>}
        {mayRevert && h.offers.length > 1 && <p className="small muted">Revert loads that version into the review below as a new offer: check it and send it. Nothing changes until you send.</p>}
      </Card>
    </div>
  );
}
