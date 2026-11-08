import { BrandMark } from '@/components/BrandMark';
import { PortalCardLink } from './PortalCardLink';
import type { PortalKey, PortalLink } from '@/server/portals';

// "Choose a portal" (0720, the owner's redesign of November 7): the brand mark, then one large card per portal the
// person has, the one they used last first: an icon, the portal's name, one line of what is there and their role in it.
// The card is one link (a large tap target on a phone); choosing it remembers the portal for next time (PortalCardLink).
export const LAST_PORTAL_COOKIE = 'cc_last_portal';

export interface PortalCard extends PortalLink { what: string; role: string; icon: PortalKey }

const ICONS: Record<PortalKey, React.ReactNode> = {
  admin: <path d="M12 3l7 3v5c0 4.5-3 8.3-7 9.5-4-1.2-7-5-7-9.5V6l7-3zM9 12l2 2 4-4" />,
  va: <path d="M4 7h16v12H4zM9 7V5h6v2M4 12h16" />,
  field: <path d="M12 21s-6-5.6-6-10.5A6 6 0 0 1 18 10.5C18 15.4 12 21 12 21zM12 12.5a2 2 0 1 0 0-4 2 2 0 0 0 0 4z" />,
  investor: <path d="M4 19h16M6 16V11M10 16V7M14 16v-5M18 16V5" />,
  owner: <path d="M5 16h14l-1.4-5.2A2 2 0 0 0 15.7 9H8.3a2 2 0 0 0-1.9 1.8L5 16zM5 16v2.5M19 16v2.5M8 13h.01M16 13h.01" />,
  account: <path d="M7 4h10v16l-5-3-5 3V4zM10 9h4" />
};

export const PORTAL_WHAT: Record<PortalKey, string> = {
  admin: 'Bookings, fleet, owners, money and every setting.',
  va: 'Your work queue, bookings and the tools of your function.',
  field: 'Your field jobs: deliveries, returns and inspections.',
  investor: 'Your statements, payments and updates.',
  owner: 'Your cars, bookings, statements and payouts.',
  account: 'Your bookings, documents and receipts.'
};

/** The cards, the last-used portal first (the rest keep their usual order). */
export function orderCards(cards: PortalCard[], last: string | null | undefined): PortalCard[] {
  const i = cards.findIndex((c) => c.key === last);
  return i > 0 ? [cards[i]!, ...cards.slice(0, i), ...cards.slice(i + 1)] : cards;
}

export function PortalChooser({ cards, email, last, banner, footer }: { cards: PortalCard[]; email: string; last: string | null; banner?: React.ReactNode; footer?: React.ReactNode }) {
  return (
    <div className="cp" data-testid="choose-portal-page">
      <div className="cp__in">
        <div className="cp__brand"><BrandMark size={44} /><span className="cp__word">CarmaCars</span></div>
        {banner}
        <header className="cp__head">
          <h1 className="d2">Choose a portal</h1>
          <p className="muted">Signed in as <b data-testid="account-email">{email}</b></p>
        </header>
        <ul className="cp__list" data-testid="choose-portal">
          {cards.map((c) => (
            <li key={c.href}>
              <PortalCardLink className={`cp-card${c.key === last ? ' is-last' : ''}`} href={c.href} portal={c.key} cookie={LAST_PORTAL_COOKIE}>
                <span className="cp-card__icon" aria-hidden="true">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{ICONS[c.icon]}</svg>
                </span>
                <span className="cp-card__body">
                  <span className="cp-card__name">{c.label}{c.key === last && <span className="cp-card__last">Last used</span>}</span>
                  <span className="cp-card__what">{c.what}</span>
                  <span className="cp-card__role">{c.role}</span>
                </span>
                <span className="cp-card__go" aria-hidden="true"><svg viewBox="0 0 20 20"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></span>
              </PortalCardLink>
            </li>
          ))}
        </ul>
        {footer}
      </div>
    </div>
  );
}
