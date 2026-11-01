import './bookings-now.css';
import Link from 'next/link';

// The Bookings section's tabs (the owner, Release 26: "There's way too many tabs at the moment and information is spread
// out too much"): Now (what is out, coming back, going out, owed and free), Requests and offers (with Chauffeur), the
// Calendar and All bookings (search and filters). Shown at the top of each, the same on every one.
export type BookingsTab = 'now' | 'requests' | 'calendar' | 'all';
export const BOOKINGS_TABS: Array<[BookingsTab, string, string]> = [
  ['now', '/admin/bookings', 'Now'], ['requests', '/admin/requests', 'Requests and offers'], ['calendar', '/admin/calendar', 'Calendar'], ['all', '/admin/bookings?view=all', 'All bookings']];

export function BookingsTabs({ current, counts = {} }: { current: BookingsTab; counts?: Partial<Record<BookingsTab, number>> }) {
  return (
    <nav className="bk-tabs" aria-label="Bookings" data-testid="bookings-tabs">
      {BOOKINGS_TABS.map(([k, href, text]) => (
        <Link key={k} prefetch={false} href={href} aria-current={k === current ? 'page' : undefined} data-testid={`bookings-tab-${k}`}>
          {text}{counts[k] ? <span className="bk-tabs__n">{counts[k]}</span> : null}
        </Link>))}
    </nav>
  );
}

/** The head of Now and All bookings: the title, what it is, the two ways to add one, then the tabs. */
export function BookingsHead({ current, lead, counts, children }: { current: BookingsTab; lead: string; counts?: Partial<Record<BookingsTab, number>>; children?: React.ReactNode }) {
  return (
    <header className="bk-head">
      <div className="bk-head__top">
        <div><h1 className="bk-head__title">Bookings</h1><p className="bk-head__lead">{lead}</p></div>
        <div className="bk-head__acts">
          {children}
          <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/offers/new" data-testid="send-offer-link">Send an offer</Link>
          <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/bookings/new" data-testid="add-rental-link">Add a rental</Link>
        </div>
      </div>
      <BookingsTabs current={current} counts={counts} />
    </header>
  );
}
