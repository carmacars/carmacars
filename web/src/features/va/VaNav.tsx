'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

// The assistant's rail: their queue first, then the working screens of their function (05-va.md sections 2 to 5).
export type Fn = 'finance' | 'fleet' | 'cs' | 'sales';
export const VA_NAV: Record<Fn, Array<[string, string]>> = {
  cs: [['/va/requests', 'Requests'], ['/va/quotes/new', 'New quote'], ['/va/bookings/new', 'Add a rental'], ['/va/messages', 'Renter messages'], ['/va/renters', 'Find a renter'], ['/va/calendar', 'Calendar'], ['/va/listings', 'Listings'], ['/va/similar-cars', 'Similar cars'], ['/va/leads', 'Owners and enquiries'], ['/va/owner-forms', 'Owner forms'], ['/va/scorecard', 'Scorecard']],
  sales: [['/va/requests', 'Requests and offers'], ['/va/quotes/new', 'New quote'], ['/va/bookings/new', 'Add a rental'], ['/va/leads', 'Owner leads'], ['/va/calendar', 'Calendar'], ['/va/scorecard', 'Scorecard']],
  finance: [['/va/money', 'Payments, deposits, refunds'], ['/va/tolls', 'Tolls and tickets'], ['/va/reconciliation', 'Reconciliation'], ['/va/turo', 'Turo trips'], ['/va/renters', 'Find a renter'], ['/va/calendar', 'Calendar'], ['/va/scorecard', 'Scorecard']],
  fleet: [['/va/fleet', 'Field jobs'], ['/va/checks', 'Daily checks'], ['/va/reviews', 'Photo reviews'], ['/va/calendar', 'Calendar'], ['/va/listings', 'Listings'], ['/va/similar-cars', 'Similar cars'], ['/va/renters', 'Find a renter'], ['/va/scorecard', 'Scorecard']]
};

export function VaNav({ fn, open }: { fn: Fn; open: number }) {
  const path = usePathname();
  const links: Array<[string, string]> = [['/va', 'Queue'], ['/va/today', 'Today'], ...VA_NAV[fn]];
  return (
    <nav className="ad-nav" aria-label="Assistant">
      <h2>Work</h2>
      <ul>{links.map(([href, text]) => (
        <li key={href} style={{ display: 'contents' }}><Link prefetch={false} href={href} aria-current={(href === '/va' ? path === '/va' || path.startsWith('/va/tasks') : path === href || path.startsWith(`${href}/`)) ? 'page' : undefined}>
          {text}{href === '/va' && open ? <span className="pt__count">{open}</span> : null}</Link></li>
      ))}</ul>
    </nav>
  );
}
