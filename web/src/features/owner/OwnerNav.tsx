'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

const LINKS = [
  { href: '/owner', label: 'Home', exact: true },
  { href: '/owner/vehicles', label: 'Vehicles' },
  { href: '/owner/bookings', label: 'Bookings' },
  { href: '/owner/invoices', label: 'Invoices' },
  { href: '/owner/statements', label: 'Statements' },
  { href: '/owner/payouts', label: 'Payouts' },
  { href: '/owner/documents', label: 'Documents' },
  { href: '/owner/banking', label: 'Banking' },
  { href: '/owner/notifications', label: 'Notifications' },
  { href: '/owner/profile', label: 'Profile' }
];

export function OwnerNav({ unread }: { unread: number }) {
  const path = usePathname() ?? '/owner';
  return (
    <nav className="pt__nav" aria-label="Owner portal">
      {LINKS.map((l) => {
        const on = l.exact ? path === l.href : path.startsWith(l.href);
        return (
          <Link key={l.href} href={l.href} aria-current={on ? 'page' : undefined}>
            {l.label}
            {l.label === 'Notifications' && unread > 0 && <span className="pt__count" aria-label={`${unread} unread`}>{unread}</span>}
          </Link>
        );
      })}
    </nav>
  );
}
