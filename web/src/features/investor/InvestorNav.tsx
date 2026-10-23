'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

// The investor portal's tabs (October 23, 2026: the same tabs as the renter and owner portals, instead of a row of
// underlined links). The deck shows while an Admin shares it; Documents to sign for investors.
const LINKS: Array<{ href: string; label: string; exact?: boolean; when?: 'deck' | 'investor' }> = [
  { href: '/investor', label: 'Investments', exact: true },
  { href: '/investor/statements', label: 'Statements' },
  { href: '/investor/sign', label: 'Documents to sign', when: 'investor' },
  { href: '/investor/deck', label: 'Investor deck', when: 'deck' },
  { href: '/investor/profile', label: 'Profile and notices' }
];

export function InvestorNav({ deck, investor }: { deck: boolean; investor: boolean }) {
  const path = usePathname() ?? '/investor';
  return (
    <nav className="pt__nav" aria-label="Investor portal">
      {LINKS.filter((l) => (l.when === 'deck' ? deck : l.when === 'investor' ? investor : true)).map((l) => (
        <Link prefetch={false} key={l.href} href={l.href} data-testid={l.when === 'deck' ? 'nav-deck' : undefined}
          aria-current={(l.exact ? path === l.href : path === l.href || path.startsWith(`${l.href}/`)) ? 'page' : undefined}>{l.label}</Link>
      ))}
    </nav>
  );
}
