'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

// The owner portal's tabs (October 23, 2026: ten tabs became six, the owner's feedback "a lot of confusion and clutter"):
// Money holds invoices, statements and payouts; Account holds the profile, banking and notifications. A tab with more
// than one page shows its pages as a row of chips under the tabs. Every page keeps its address.
type Tab = { href: string; label: string; exact?: boolean; pages?: Array<{ href: string; label: string }> };
const TABS: Tab[] = [
  { href: '/owner', label: 'Home', exact: true },
  { href: '/owner/vehicles', label: 'Vehicles' },
  { href: '/owner/bookings', label: 'Bookings' },
  { href: '/owner/invoices', label: 'Money', pages: [{ href: '/owner/invoices', label: 'Invoices' }, { href: '/owner/statements', label: 'Statements' }, { href: '/owner/payouts', label: 'Payouts' }] },
  { href: '/owner/documents', label: 'Documents' },
  { href: '/owner/profile', label: 'Account', pages: [{ href: '/owner/profile', label: 'Profile' }, { href: '/owner/banking', label: 'Banking' }, { href: '/owner/notifications', label: 'Notifications' }] }
];

// A partner rental company (0046) uses the same portal: no invoices (it pays no program fees), and its partner agreement.
function tabsFor(partner: boolean): Tab[] {
  if (!partner) return TABS;
  return TABS.map((t) => t.label === 'Money' ? { ...t, href: '/owner/statements', pages: t.pages!.filter((p) => p.href !== '/owner/invoices') }
    : t.label === 'Documents' ? { ...t, pages: [{ href: '/owner/documents', label: 'Documents' }, { href: '/owner/partner-agreement', label: 'Partner agreement' }] } : t);
}
const on = (path: string, href: string, exact?: boolean) => (exact ? path === href : path === href || path.startsWith(`${href}/`));

export function OwnerNav({ unread, partner = false }: { unread: number; partner?: boolean }) {
  const path = usePathname() ?? '/owner';
  const tabs = tabsFor(partner);
  const current = tabs.find((t) => (t.pages ?? [t]).some((p) => on(path, p.href, t.exact)));
  const count = (href: string) => (href === '/owner/notifications' && unread > 0 ? <span className="pt__count" aria-label={`${unread} unread`}>{unread}</span> : null);
  return (
    <>
      <nav className="pt__nav" aria-label={partner ? 'Partner portal' : 'Owner portal'}>
        {tabs.map((t) => (
          <Link key={t.label} href={t.href} aria-current={current === t ? 'page' : undefined}>
            {t.label}
            {t.label === 'Account' && unread > 0 && <span className="pt__count" aria-label={`${unread} unread`}>{unread}</span>}
          </Link>
        ))}
      </nav>
      {current?.pages && (
        <nav className="pt__subnav" aria-label={current.label} data-testid="owner-subnav">
          {current.pages.map((p) => <Link key={p.href} href={p.href} aria-current={on(path, p.href) ? 'page' : undefined}>{p.label}{count(p.href)}</Link>)}
        </nav>
      )}
    </>
  );
}
