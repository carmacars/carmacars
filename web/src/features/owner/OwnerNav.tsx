'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

const LINKS: Array<{ href: string; label: string; exact?: boolean }> = [
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

// A partner rental company (0046) uses the same portal: no invoices (it pays no program fees), and its partner agreement.
export function OwnerNav({ unread, partner = false }: { unread: number; partner?: boolean }) {
  const path = usePathname() ?? '/owner';
  const links = partner ? [...LINKS.filter((l) => l.href !== '/owner/invoices').slice(0, 5), { href: '/owner/partner-agreement', label: 'Partner agreement' }, ...LINKS.filter((l) => l.href !== '/owner/invoices').slice(5)] : LINKS;
  return (
    <nav className="pt__nav" aria-label={partner ? 'Partner portal' : 'Owner portal'}>
      {links.map((l) => {
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
