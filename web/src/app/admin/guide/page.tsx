import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { GUIDE_NAME, GUIDE_PORTALS, guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Admin guide', path: '/admin/guide', noindex: true, description: 'Every booking, car, owner and dollar, run from one place.' });

export default async function AdminGuide() {
  const { user } = await requireAdmin('/admin/guide');
  return (<>
    <nav className="row small gd-noprint" aria-label="Every guide" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
      <span className="muted">Guides:</span>{GUIDE_PORTALS.map((p) => <Link prefetch={false} key={p} className="link" href={p === 'admin' ? '/admin/guide' : `/admin/guide/${p}`} aria-current={p === 'admin' ? 'page' : undefined}>{GUIDE_NAME[p]}</Link>)}
      <Link prefetch={false} className="link" href="/admin/settings/guides">Edit the guides</Link>
    </nav>
    <GuideView g={await guideFor(user, 'admin')} portal="admin" pdfHref="/guide-pdf/admin" admin />
  </>);
}
