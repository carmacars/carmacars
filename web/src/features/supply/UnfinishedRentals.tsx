import './unfinished.css';
import Link from '@/components/Link';
import type { DraftRow } from '@/server/actions/supply';
import { draftHref, draftLine, draftMissing, split, type DraftBase } from './unfinished';

// Unfinished rentals (0148): the drafts saved as they were typed, everyone's, newest first; each opens where it was left.
// r48 ops (the owner, Nov 20): the section sat on pages where it made no sense (above every Add a rental and Send an offer
// form, on every staff function's Today). It now belongs to the people who chase a sale to its end: the Admin's Today and
// Bookings, and Sales' Today and Bookings. The forms keep one quiet line for the person's own drafts (MyDrafts below), so
// nobody loses what they typed.
export function UnfinishedRentals({ rows, base, title = 'Unfinished rentals' }: { rows: DraftRow[]; base: DraftBase; title?: string }) {
  if (!rows.length) return null;
  const { first, rest } = split(rows);
  const row = (r: DraftRow) => (
    <li key={r.id} className="unf__row" data-testid="unfinished-row" data-mine={r.mine ? 'yes' : undefined}>
      <div className="unf__main">
        <p className="unf__title"><b>{r.title || r.vehicle || 'Not named yet'}</b>
          {r.quick && <span className="unf__tag">Started at pickup</span>}
          {r.held_until && <span className="unf__tag unf__tag--held" data-testid="unfinished-held">Car held until {new Date(r.held_until).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' })}</span>}</p>
        <p className="unf__meta">{draftLine(r)}</p>
        {r.missing.length > 0
          ? <p className="unf__missing"><span className="unf__k">Still missing</span>{draftMissing(r).shown.map((m) => <span key={m} className="unf__chip">{m}</span>)}{draftMissing(r).more > 0 && <span className="unf__chip unf__chip--more">+{draftMissing(r).more} more</span>}</p>
          : <p className="unf__ready">Everything is in: ready to add</p>}
      </div>
      <Link prefetch={false} className="btn btn--primary btn--sm unf__go" href={draftHref(r, base)}>{r.kind === 'offer' ? 'Open the offer' : 'Finish it'}</Link>
    </li>);
  return (
    <section className="unf" aria-labelledby="unfinished-h" data-testid="unfinished-rentals">
      <header className="unf__head">
        <h2 className="unf__h" id="unfinished-h">{title} <span className="unf__count" aria-label={`${rows.length} unfinished`}>{rows.length}</span></h2>
        <p className="unf__note">Started and saved as typed, not yet a booking. Finish each one or discard it from its form.</p>
      </header>
      <ul className="unf__list">{first.map(row)}</ul>
      {rest.length > 0 && <details className="unf__more"><summary data-testid="unfinished-more">Show {rest.length} older</summary><ul className="unf__list">{rest.map(row)}</ul></details>}
    </section>
  );
}

/** On a form (Add a rental, Send an offer): the person's own drafts, one quiet line each, never everyone's section. */
export function MyDrafts({ rows, base, current }: { rows: DraftRow[]; base: DraftBase; current?: string | null }) {
  const mine = rows.filter((r) => r.mine && r.id !== current);
  if (!mine.length) return null;
  return (
    <p className="unf-mine" role="note" data-testid="my-drafts">
      <span>You have {mine.length === 1 ? 'an unfinished one' : `${mine.length} unfinished`}:</span>
      {mine.slice(0, 3).map((r) => <Link prefetch={false} key={r.id} className="link" href={draftHref(r, base)} data-testid="my-draft-link">{r.title || r.vehicle || 'Not named yet'}</Link>)}
      {mine.length > 3 && <span className="muted">and {mine.length - 3} more on {base === '/staff/field' ? 'this page later' : 'Bookings'}</span>}
    </p>
  );
}
