import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { GUIDE_NAME, GUIDE_PORTALS, guideFor, isGuidePortal } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Guide', path: '/admin/guide', noindex: true, description: 'A portal guide, as its people see it.' });

// An Admin reads every portal's guide as it is published (its own page, without viewing as anyone).
export default async function AnyGuide({ params }: { params: Promise<{ portal: string }> }) {
  const [{ user }, { portal }] = await Promise.all([requireAdmin('/admin/guide'), params]);
  if (!isGuidePortal(portal)) notFound();
  return (<>
    <nav className="row small gd-noprint" aria-label="Every guide" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
      <span className="muted">Guides:</span>{GUIDE_PORTALS.map((p) => <Link prefetch={false} key={p} className="link" href={p === 'admin' ? '/admin/guide' : `/admin/guide/${p}`} aria-current={p === portal ? 'page' : undefined}>{GUIDE_NAME[p]}</Link>)}
      <Link prefetch={false} className="link" href={`/admin/settings/guides/${portal}`}>Edit this guide</Link>
    </nav>
    <GuideView g={await guideFor(user, portal, false)} portal={portal} pdfHref={`/guide-pdf/${portal}`} admin />
  </>);
}
