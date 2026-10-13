'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

// The assistant's rail: their queue first, then the working screens of their function (05-va.md sections 2 to 5).
export type Fn = 'finance' | 'fleet' | 'cs' | 'sales';
export const VA_NAV: Record<Fn, Array<[string, string]>> = {
  cs: [['/va/requests', 'Requests'], ['/va/messages', 'Renter messages'], ['/va/calendar', 'Calendar'], ['/va/listings', 'Listings'], ['/va/leads', 'Owners and enquiries']],
  sales: [['/va/requests', 'Requests and offers'], ['/va/leads', 'Owner leads'], ['/va/calendar', 'Calendar']],
  finance: [['/va/money', 'Payments, deposits, refunds'], ['/va/tolls', 'Tolls and tickets'], ['/va/calendar', 'Calendar']],
  fleet: [['/va/fleet', 'Field jobs'], ['/va/calendar', 'Calendar'], ['/va/listings', 'Listings']]
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
