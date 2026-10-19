import { Suspense } from 'react';
import { GroupNav, type NavGroup } from '@/features/admin/GroupNav';

// The assistant's navigation (05-va.md sections 2 to 5; grouped with plain names since October 16, 2026, like the admin
// portal): their work first, then the screens of their function in a few groups. The pages keep their addresses.
export type Fn = 'finance' | 'fleet' | 'cs' | 'sales';
// every function sees its own sales and commissions (0057 for Sales, 0058 for all)
const WORK: NavGroup = { key: 'work', label: 'My work', links: [{ href: '/va', label: 'To do', key: 't' }, { href: '/va/today', label: 'Today' }, { href: '/va/scorecard', label: 'My scorecard' }, { href: '/va/my-sales', label: 'My sales' }] };
// customer service and Sales also watch the site and answer the live chat (0060)
const LIVE_WORK: NavGroup = { key: 'work', label: 'My work', links: [{ href: '/va', label: 'To do', key: 't' }, { href: '/va/today', label: 'Today' }, { href: '/va/scorecard', label: 'My scorecard' }, { href: '/va/my-sales', label: 'My sales' }, { href: '/va/live', label: 'Live visitors' }, { href: '/va/chat', label: 'Live chat' }] };
const SALES_WORK = LIVE_WORK;
// every function adds rentals and takes quotes (0058)
const SELL: NavGroup = { key: 'sell', label: 'Rentals', links: [{ href: '/va/bookings/new', label: 'Add a rental' }, { href: '/va/quotes/new', label: 'New quote' }] };
export const VA_GROUPS: Record<Fn, NavGroup[]> = {
  cs: [LIVE_WORK,
    { key: 'bookings', label: 'Bookings', links: [{ href: '/va/requests', label: 'Requests', key: 'r' }, { href: '/va/quotes/new', label: 'New quote' }, { href: '/va/bookings/new', label: 'Add a rental' }, { href: '/va/calendar', label: 'Calendar', key: 'c' }] },
    { key: 'renters', label: 'Renters', links: [{ href: '/va/messages', label: 'Messages' }, { href: '/va/renters', label: 'Find a renter' }] },
    { key: 'cars', label: 'Cars', links: [{ href: '/va/listings', label: 'Listings' }, { href: '/va/similar-cars', label: 'Similar cars' }] },
    { key: 'owners', label: 'Owners', links: [{ href: '/va/leads', label: 'Owners and enquiries' }, { href: '/va/owner-forms', label: 'Owner forms' }] }],
  sales: [SALES_WORK,
    { key: 'bookings', label: 'Bookings', links: [{ href: '/va/requests', label: 'Requests and offers', key: 'r' }, { href: '/va/quotes/new', label: 'New quote' }, { href: '/va/bookings/new', label: 'Add a rental' }, { href: '/va/calendar', label: 'Calendar', key: 'c' }] },
    { key: 'owners', label: 'Owners', links: [{ href: '/va/leads', label: 'Owner leads' }] }],
  finance: [WORK,
    { key: 'money', label: 'Money', links: [{ href: '/va/money', label: 'Payments, deposits and refunds' }, { href: '/va/tolls', label: 'Tolls and tickets' }, { href: '/va/reconciliation', label: 'Reconciliation' }, { href: '/va/turo', label: 'Turo trips' }] },
    { key: 'renters', label: 'Renters and bookings', links: [{ href: '/va/renters', label: 'Find a renter' }, { href: '/va/calendar', label: 'Calendar', key: 'c' }] }, SELL],
  fleet: [WORK,
    { key: 'field', label: 'Field work', links: [{ href: '/va/fleet', label: 'Field jobs' }, { href: '/va/checks', label: 'Daily checks' }, { href: '/va/reviews', label: 'Photo reviews' }] },
    { key: 'cars', label: 'Cars', links: [{ href: '/va/listings', label: 'Listings' }, { href: '/va/similar-cars', label: 'Similar cars' }, { href: '/va/calendar', label: 'Calendar', key: 'c' }, { href: '/va/calendar-sync', label: 'Calendar sync' }] },
    { key: 'renters', label: 'Renters', links: [{ href: '/va/renters', label: 'Find a renter' }] }, SELL]
};
/** Every page of a function (kept for the crawl and the guide's quick reference). */
export const VA_NAV: Record<Fn, Array<[string, string]>> = Object.fromEntries(
  (Object.keys(VA_GROUPS) as Fn[]).map((f) => [f, VA_GROUPS[f].flatMap((g) => g.links).filter((l) => !['/va', '/va/today'].includes(l.href)).map((l) => [l.href, l.label] as [string, string])])) as Record<Fn, Array<[string, string]>>;

export function VaNav({ fn, open, chat = 0 }: { fn: Fn; open: number; chat?: number }) {
  return (
    <Suspense fallback={<nav className="gn" aria-label="Assistant" />}>
      <GroupNav groups={VA_GROUPS[fn]} counts={{ '/va': open, '/va/chat': chat }} label="Assistant" testId="va-nav" />
    </Suspense>
  );
}
