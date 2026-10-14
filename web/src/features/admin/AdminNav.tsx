'use client';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useEffect } from 'react';

// The admin portal's rail: grouped links on a desktop, one scrolling strip on a phone. Keyboard: "g"
// then a letter goes to a section (t today, r requests, b bookings, c calendar, v vehicles, l listings,
// m money, o tolls, k tasks, s settings); "/" focuses the page's search.
export const NAV: Array<[string, Array<[string, string, string?]>]> = [
  ['Operate', [['/admin', 'Today', 't'], ['/admin/requests', 'Requests', 'r'], ['/admin/bookings', 'Bookings', 'b'], ['/admin/calendar', 'Calendar', 'c'], ['/admin/tasks', 'Tasks', 'k']]],
  ['Fleet', [['/admin/vehicles', 'Vehicles', 'v'], ['/admin/listings', 'Listings', 'l'], ['/admin/vehicles/bulk-rates', 'Bulk rates']]],
  ['Money', [['/admin/money', 'Payments and refunds', 'm'], ['/admin/insurer-invoices', 'Insurer invoices'], ['/admin/invoices', 'Owner invoices'], ['/admin/debits', 'Owner debits'], ['/admin/statements', 'Owner statements'], ['/admin/payouts', 'Payouts'], ['/admin/reports', 'Company statements'], ['/admin/expenses', 'Expenses'], ['/admin/reconciliation', 'Reconciliation']]],
  ['Recover', [['/admin/tolls', 'Tolls and tickets', 'o'], ['/admin/damages', 'Damage'], ['/admin/incidents', 'Incidents and claims']]],
  ['People', [['/admin/portals', 'Portals and sign-in'], ['/admin/settings/staff', 'Staff'], ['/admin/owners', 'Owners'], ['/admin/investors', 'Investors'], ['/admin/reviews', 'Reviews'], ['/admin/messages', 'Email'], ['/admin/audit', 'Audit log']]],
  ['Setup', [['/admin/settings', 'Settings', 's']]]
];

export function AdminNav({ counts }: { counts: Record<string, number> }) {
  const path = usePathname();
  const router = useRouter();
  const active = (href: string) => href === '/admin' ? path === '/admin' : path === href || (path.startsWith(`${href}/`) && !NAV.some(([, l]) => l.some(([h]) => h !== href && h.startsWith(`${href}/`) && path.startsWith(h))));
  useEffect(() => {
    let g = false; let t: ReturnType<typeof setTimeout> | undefined;
    const keys = new Map(NAV.flatMap(([, l]) => l.filter((x) => x[2]).map((x) => [x[2]!, x[0]] as [string, string])));
    const on = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      if (el && (el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === '/') { const s = document.querySelector<HTMLInputElement>('[data-shortcut="/"]'); if (s) { e.preventDefault(); s.focus(); } return; }
      if (g) { const href = keys.get(e.key); g = false; if (href) { e.preventDefault(); router.push(href); } return; }
      if (e.key === 'g') { g = true; clearTimeout(t); t = setTimeout(() => { g = false; }, 900); }
    };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [router]);
  return (
    <nav className="ad-nav" aria-label="Admin">
      {NAV.map(([group, links]) => (
        <div key={group} style={{ display: 'contents' }}>
          <h2>{group}</h2>
          <ul>{links.map(([href, text]) => (
            <li key={href} style={{ display: 'contents' }}><Link prefetch={false} href={href} aria-current={active(href) ? 'page' : undefined}>{text}{counts[href] ? <span className="pt__count">{counts[href]}</span> : null}</Link></li>
          ))}</ul>
        </div>
      ))}
    </nav>
  );
}
