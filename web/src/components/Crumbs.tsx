import Link from 'next/link';
import type { Trail } from '@/features/seo/meta';

export function Crumbs({ trail }: { trail: Trail }) {
  return (
    <nav className="crumbs" aria-label="Breadcrumb"><ol>
      {trail.map(([label, href], i) => i < trail.length - 1 && href
        ? <li key={i}><Link prefetch={false} href={href}>{label}</Link></li>
        : <li key={i}><span aria-current="page">{label}</span></li>)}
    </ol></nav>
  );
}
