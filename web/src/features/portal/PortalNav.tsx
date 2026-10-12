'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

const LINKS = [
  { href: '/account', label: 'Trips', match: (p: string) => p === '/account' || p.startsWith('/account/bookings') },
  { href: '/account/documents', label: 'Documents', match: (p: string) => p.startsWith('/account/documents') },
  { href: '/account/notifications', label: 'Notifications', match: (p: string) => p.startsWith('/account/notifications') },
  { href: '/account/profile', label: 'Profile', match: (p: string) => p.startsWith('/account/profile') }
];

export function PortalNav({ unread }: { unread: number }) {
  const path = usePathname() ?? '/account';
  return (
    <nav className="pt__nav" aria-label="Your account">
      {LINKS.map((l) => (
        <Link key={l.href} href={l.href} aria-current={l.match(path) ? 'page' : undefined}>
          {l.label}
          {l.label === 'Notifications' && unread > 0 && <span className="pt__count" aria-label={`${unread} unread`}>{unread}</span>}
        </Link>
      ))}
    </nav>
  );
}
