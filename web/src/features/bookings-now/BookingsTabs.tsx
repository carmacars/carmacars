import './bookings-now.css';
import Link from '@/components/Link';

// Bookings' two tabs (the owner, Release 26: "There's way too many tabs at the moment and information is spread out too
// much", "We need less pages not more"): Now (what is out, coming back, going out, owed and free) and All bookings (the
// search and the list by status). Requests and offers and the Calendar are the menu's other two Trips pages.
export type BookingsTab = 'now' | 'all';
export const BOOKINGS_TABS: Array<[BookingsTab, string, string]> = [['now', '/admin/bookings', 'Now'], ['all', '/admin/bookings?view=all', 'All bookings']];

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
