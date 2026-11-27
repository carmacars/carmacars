import Link from '@/components/Link';
import { OWNER_TRIP } from '@/features/request-history/model';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { ReopenOffer } from '@/features/offers/ReopenOffer';
import { Act } from '@/features/admin/Act';
import { LiveWait } from '@/features/admin/shell/LiveWait';
import { opensToYou, type ClaimInfo } from '@/features/offers/claim';
import { CarLine, Chip, Tile, TileBand, Who } from './parts';
import { Countdown } from './Countdown';
import { expiredForLong, money, when, type Car } from './model';
import { waitWords } from '@/lib/wait-words';
import { torontoInputOf } from '@/lib/dates';
import type { Cards } from './cards';

// Requests and offers (Release 26 part 2, migration 0332), the same for an Admin and for customer service, fleet and
// Sales: the counts on black, then one queue by urgency. A request waiting for its first offer comes first, the longest
// wait first, with how long the renter has waited (red past the staff's first reply target) and the countdown to what
// the site promises the renter ("within 2 hours"). Then the offers waiting for payment, the offers out (soonest expiry
// first, with the expiry), and the expired ones. Each row: the car with its photo, the dates, the price, the renter with
// Call and Text, the licence, who is answering it, and one clear action. The claim rules of 0177 hold: a request someone
// else is answering opens read-only, and Sales waits until it opens to them.
export type Req = { id: string; booking_number: string; status: string; state: string; vehicle: string; renter: string; returning: boolean; pickup_at: string; return_at: string; days: number;
  total_cents: number; waiting_minutes: number; offer_expires_at: string | null; flags: string[]; drivers?: string[]; assigned?: string | null;
  claim?: ClaimInfo | null; sales_opens_at?: string | null; sales_waits?: boolean;
  /** 5130: an enquiry on a sample car (a lead, not a booking): its contact and the real cars to offer instead */
  sample?: boolean; lead_id?: string; contact?: { email?: string; phone?: string }; note?: string | null;
  suggestions?: Array<{ id: string; name: string; slug: string; same_class: boolean }>;
  /** 5132: the renter's notes on their request */ renter_notes?: Array<{ id: string; body: string; at: string }> };

/** What the site promises a renter for the first answer (site_settings.reply_wording: "within 2 hours"). */
export const PROMISE_MINUTES = 120;
const RANK: Record<string, number> = { requested: 0, pending_payment: 1, offered: 2, expired: 3 };
const STATE_WORDS: Record<string, string> = { sample: 'Sample car enquiry', new: 'New request', waiting_on_renter: 'Asked the renter', pushed_back: 'Renter asked for changes', offer_out: 'Offer out', awaiting_payment: 'Accepted, not paid', expired: 'Offer expired' };
const FLAG_RED = new Set(['Conflict', 'Blocked renter', 'Under 21']);

export function sortRequests(rows: Req[]): Req[] {
  return [...rows].sort((a, b) => (RANK[a.status] ?? 4) - (RANK[b.status] ?? 4)
    || (a.status === 'requested' ? b.waiting_minutes - a.waiting_minutes
      : a.status === 'offered' ? (a.offer_expires_at ?? '9').localeCompare(b.offer_expires_at ?? '9') : a.pickup_at.localeCompare(b.pickup_at)));
}

/** An expired offer leaves the active queue for the quiet Expired filter 48 hours after it expired, or once its pickup passed.
 *  Release 33: after 7 days expired it leaves the list altogether and becomes a renter lead (Marketing > Leads, migration 0741). */
export function archived(r: Req, c: Cards[string] | undefined, at: number): boolean {
  if (r.status !== 'expired') return false;
  if (new Date(r.pickup_at).getTime() < at) return true;
  return !!c?.expired_at && at - new Date(c.expired_at).getTime() > 48 * 3600_000;
}

export function RequestsQueue({ all: everyone, cards, state, sp, target, at, base, admin, sales = false }: {
  all: Req[]; cards: Cards; state: string; sp: Record<string, string | undefined>; target: { minutes: number; words: string }; at: number; base: '/admin' | '/staff'; admin: boolean;
  /** Sales see only what they can act on now; the rest waits in a folded list */ sales?: boolean;
}) {
  // r33: expired 7 days or more: no longer listed here, it is a renter lead now (Renters > Leads; migration 0741)
  const every = everyone.filter((r) => !expiredForLong(r.status, cards[r.id]?.expired_at, at));
  const old = every.filter((r) => archived(r, cards[r.id], at));
  const all = state === 'expired' ? every : every.filter((r) => !archived(r, cards[r.id], at));
  const notYet = (r: Req) => sales && r.status === 'requested' && (!!r.sales_waits || (!!r.claim && !r.claim.mine));
  const n = (st: string) => (st === 'expired' ? every : all).filter((r) => r.state === st).length;
  const waiting = all.filter((r) => r.status === 'requested' && !notYet(r));
  const late = waiting.filter((r) => r.waiting_minutes > target.minutes).length;
  const listed = all.filter((r) => !state || (state === 'late' ? r.status === 'requested' && r.waiting_minutes > target.minutes : r.state === state));
  const rows = sortRequests(listed.filter((r) => !notYet(r)));
  const later = listed.filter(notYet);
  const refresh = [`${base}/requests`];
  return (
    <div className="bn rq-page" data-testid="requests-queue" data-guide="rq-queue">
      <TileBand label="Requests and offers in numbers">
        <Tile k="rq-new" current={state === 'new'} href={`${base}/requests?state=new`} label="Waiting for an offer" n={waiting.length} note={`reply within ${target.words}`} />
        <Tile k="rq-late" current={state === 'late'} href={`${base}/requests?state=late`} label="Past the reply target" n={late} urgent={late > 0} note={late ? 'answer these first' : 'none late'} />
        <Tile k="rq-out" current={state === 'offer_out'} href={`${base}/requests?state=offer_out`} label="Offers out" n={n('offer_out')} note="waiting on the renter" />
        <Tile k="rq-pay" current={state === 'awaiting_payment'} href={`${base}/requests?state=awaiting_payment`} label="Accepted, not paid" n={n('awaiting_payment')} note="follow up for payment" />
        <Tile k="rq-exp" current={state === 'expired'} href={`${base}/requests?state=expired`} label="Offers expired" n={all.filter((r) => r.state === 'expired').length} note={old.length ? `${old.length} older in Expired` : 'send again or close'} />
      </TileBand>
      <div className="bn-bar">
        <ListFilters id="bookings-now-requestsqueue-state" base={`${base}/requests`} sp={sp} chips={{ name: 'state', label: 'State', value: state === 'late' ? 'new' : state, options: [['', `Active (${all.length})`], ['new', `New (${n('new')})`],           ['pushed_back', `Changes asked (${n('pushed_back')})`], ['offer_out', `Offer out (${n('offer_out')})`], ['awaiting_payment', `Accepted, not paid (${n('awaiting_payment')})`], ['expired', `Expired (${n('expired')})`]] }} />
      </div>
      {rows.length ? (
        <div className="rq-list" role="list" data-testid="requests">
          {rows.map((r) => (r.sample ? <SampleRow key={r.id} r={r} target={target.minutes} at={at} base={base} />
            : <RequestRow key={r.id} r={r} c={cards[r.id]} target={target.minutes} at={at} base={base} admin={admin} refresh={refresh} />))}
        </div>
      ) : <p className="bn-none" data-testid="requests-empty">{every.length ? (later.length ? 'Nothing to answer right now.' : 'No request in this state. Choose Active to see the queue.') : 'No requests waiting. New booking requests from the website show up here to price and offer.'}</p>}
      {later.length > 0 && (
        <details className="rq-later" data-testid="rq-later">
          <summary>{later.length} more not open to you yet</summary>
          <ul>{later.map((r) => (
            <li key={r.id}><b>{r.booking_number}</b> {r.vehicle}, {r.renter} <span className="rq__claim" data-testid={`claim-${r.booking_number}`}>{r.sales_waits ? opensToYou(r.sales_opens_at) : r.claim?.text}</span></li>))}</ul>
        </details>)}
    </div>
  );
}

function RequestRow({ r, c, target, at, base, admin, refresh }: { r: Req; c: Cards[string] | undefined; target: number; at: number; base: string; admin: boolean; refresh: string[] }) {
  const car: Car = c?.car ?? { id: r.id, name: r.vehicle, code: null, plate: null, photo: null };
  const href = `${base}/bookings/${encodeURIComponent(r.booking_number)}`;
  const requested = r.status === 'requested';
  const otherHolds = requested && !!r.claim && !r.claim.mine;
  const waits = requested && !!r.sales_waits;
  const free = requested && !otherHolds && !waits;
  const promise = new Date(at - r.waiting_minutes * 60_000 + PROMISE_MINUTES * 60_000).toISOString();
  const lic = c?.licence ?? 'missing';
  const tone = requested ? (r.waiting_minutes > target ? 'is-late' : 'is-new') : r.status === 'expired' ? 'is-expired' : 'is-offer';
  // one clear next step
  const primary = free || r.state === 'pushed_back'
    ? { label: 'Send offer', href: admin ? `${href}?tab=review` : href, kind: 'primary' }
    : ['offered', 'pending_payment'].includes(r.status) || r.state === 'waiting_on_renter' ? { label: 'Follow up', href, kind: 'primary' }
    : { label: 'Open', href, kind: 'ghost' };
  return (
    <article className={`rq ${tone}`} role="listitem" data-testid={`rq-${r.booking_number}`}>
      <div className="rq__when">
        {requested ? <>
          <span className="bn-k">Waiting</span>
          <b className="rq__wait"><LiveWait key={`${r.id}-${r.waiting_minutes}`} minutes={r.waiting_minutes} target={target} /></b>
          <span className="rq__promise">Promise <Countdown to={promise} at={at} left="left" over="over" testId={`rq-promise-${r.booking_number}`} /></span>
        </> : r.status === 'offered' && r.offer_expires_at ? <>
          <span className="bn-k">Offer expires</span><b className="rq__wait">{when(r.offer_expires_at, at)}</b>
          <span className="rq__promise"><Countdown to={r.offer_expires_at} at={at} left="left" over="ago" /></span>
        </> : <>
          <span className="bn-k">{r.status === 'pending_payment' ? 'Accepted' : 'Waited'}</span><b className="rq__wait">{waitWords(r.waiting_minutes)}</b>
        </>}
      </div>
      <div className="rq__car">
        <CarLine car={car} number={r.booking_number} href={href} />
        <span className="rq__dates"><b>{when(r.pickup_at, at)}</b> to {when(r.return_at, at)} <span className="rq__days">{r.days} day{r.days === 1 ? '' : 's'}</span></span>
      </div>
      <div className="rq__who">
        <Who r={{ id: r.id, name: r.renter, phone: c?.phone ?? null }} booking={r.booking_number} />
        <span className="rq__tags">
          {c?.owner_trip && <Chip tone="amber" testId={`rq-owner-${r.booking_number}`}>{OWNER_TRIP}</Chip>}
          <Chip tone={r.returning ? 'ok' : 'quiet'}>{r.returning ? 'Returning' : 'New renter'}</Chip>
          <Chip tone={lic === 'verified' ? 'ok' : lic === 'pending' ? 'amber' : 'red'} testId={`rq-licence-${r.booking_number}`}>{lic === 'verified' ? 'Licence verified' : lic === 'pending' ? 'Licence to review: not bookable until verified' : 'No licence yet: not bookable until verified'}</Chip>
          {c?.bill_to && c.bill_to !== 'renter' && <Chip tone="dark">Insurer</Chip>}
          {r.flags.map((f) => <Chip key={f} tone={FLAG_RED.has(f) ? 'red' : 'amber'}>{f}</Chip>)}
        </span>
      </div>
      {r.renter_notes && r.renter_notes.length > 0 && <div className="rq__notes" data-testid={`rq-notes-${r.booking_number}`}>
        <span className="bn-k">Renter&apos;s note{r.renter_notes.length === 1 ? '' : `s (${r.renter_notes.length})`}</span>
        <p>{r.renter_notes[r.renter_notes.length - 1]!.body}</p></div>}
      <div className="rq__money"><span className="bn-k">Price</span><b>{money(r.total_cents)}</b></div>
      <div className="rq__act">
        <Chip tone={requested ? (r.waiting_minutes > target ? 'red' : 'dark') : r.status === 'expired' ? 'quiet' : 'amber'}>{STATE_WORDS[r.state] ?? r.state.replace(/_/g, ' ')}</Chip>
        {(otherHolds || waits || (requested && r.claim?.mine)) && <span className="rq__claim" data-testid={`claim-${r.booking_number}`}>{waits ? opensToYou(r.sales_opens_at) : r.claim!.mine ? 'You are answering it' : r.claim!.text}</span>}
        {!requested && r.assigned ? <span className="rq__claim">{r.assigned}</span> : null}
        <span className="rq__btns">
          <Link prefetch={false} className={`btn btn--sm btn--${primary.kind}`} href={primary.href} data-testid={`rq-go-${r.booking_number}`} data-guide="rq-go">{primary.label}</Link>
          {admin && free && <Act action="decline_request" payload={{ booking: r.id }} label="Decline" title={`Decline ${r.booking_number}`}
            fields={[{ name: 'note', label: 'Reason and any alternative', type: 'textarea', required: true }]} refresh={refresh} />}
          {r.status === 'expired' && <ReopenOffer booking={r.id} pickupAt={r.pickup_at} returnAt={r.return_at} refresh={refresh} testId={`rq-reopen-${r.booking_number}`} />}
        </span>
      </div>
    </article>
  );
}

// 5130: an enquiry on a sample car (an example car, not a real one) waits here like a request: who asked, for which dates,
// and up to three real cars free then to offer instead. Send an offer opens the offer form on the first one with the dates.
function SampleRow({ r, target, at, base }: { r: Req; target: number; at: number; base: string }) {
  const lead = `${base}/sales-leads/${r.lead_id ?? r.id}`;
  const dates = `from=${encodeURIComponent(torontoInputOf(r.pickup_at))}&to=${encodeURIComponent(torontoInputOf(r.return_at))}`;
  const first = r.suggestions?.[0];
  const offer = `${base}/offers/new?${first ? `car=${first.id}&` : ''}${dates}`;
  return (
    <article className={`rq rq--sample ${r.waiting_minutes > target ? 'is-late' : 'is-new'}`} role="listitem" data-testid={`rq-${r.booking_number}`}>
      <div className="rq__when">
        <span className="bn-k">Waiting</span>
        <b className="rq__wait"><LiveWait key={`${r.id}-${r.waiting_minutes}`} minutes={r.waiting_minutes} target={target} /></b>
      </div>
      <div className="rq__car">
        <span className="bn-carline"><span className="bn-carline__text"><span className="bn-carline__name">{r.vehicle}</span>
          <span className="bn-carline__id">{r.booking_number}</span></span></span>
        <span className="rq__dates"><b>{when(r.pickup_at, at)}</b> to {when(r.return_at, at)} <span className="rq__days">{r.days} day{r.days === 1 ? '' : 's'}</span></span>
      </div>
      <div className="rq__who">
        <Who r={{ id: r.id, name: r.renter, phone: r.contact?.phone ?? null }} booking={null} />
        <span className="rq__tags">
          <Chip tone="amber" testId={`rq-sample-${r.booking_number}`}>Sample car: not a real car</Chip>
          {r.contact?.email && <Chip tone="quiet">{r.contact.email}</Chip>}
        </span>
        {r.note && <p className="rq__note small">{r.note}</p>}
      </div>
      <div className="rq__suggest" data-testid={`rq-suggest-${r.booking_number}`}>
        <span className="bn-k">Offer a real car</span>
        {r.suggestions && r.suggestions.length > 0
          ? <ul>{r.suggestions.map((x) => <li key={x.id}><Link prefetch={false} className="bn-link" href={`${base}/offers/new?car=${x.id}&${dates}`}>{x.name}</Link>{x.same_class ? <span className="muted small"> same class</span> : null}</li>)}</ul>
          : <p className="small muted">No real car is free for these dates: call to suggest other dates.</p>}
      </div>
      <div className="rq__act">
        <Chip tone={r.waiting_minutes > target ? 'red' : 'dark'}>{STATE_WORDS.sample}</Chip>
        {r.assigned ? <span className="rq__claim">{r.assigned}</span> : null}
        <span className="rq__btns">
          <Link prefetch={false} className="btn btn--sm btn--primary" href={offer} data-testid={`rq-go-${r.booking_number}`}>Send an offer</Link>
          <Link prefetch={false} className="btn btn--sm btn--ghost" href={lead} data-testid={`rq-lead-${r.booking_number}`}>Open the enquiry</Link>
        </span>
      </div>
    </article>
  );
}
