'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

// The field portal's few places (06-field.md sections 2, 9 and 10).
const LINKS: Array<[string, string]> = [['/field', 'My jobs'], ['/field/report', 'Report'], ['/field/referrals', 'Referrals'], ['/field/profile', 'Profile']];
export function FieldNav() {
  const path = usePathname();
  return <nav className="fd-nav" aria-label="Field">{LINKS.map(([h, l]) => (
    <Link key={h} prefetch={false} href={h} aria-current={(h === '/field' ? path === '/field' || path.startsWith('/field/jobs') : path.startsWith(h)) ? 'page' : undefined}>{l}</Link>))}</nav>;
}
