import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Card, PageHead, Table, d, t } from '@/features/admin/ui';
import { GuideEditor, type EditorGuide } from '@/features/guides/GuideEditor';
import { GUIDE_PATH, isGuidePortal } from '@/server/guides';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Edit a guide', path: '/admin/settings/guides', noindex: true, description: 'Edit, publish and print a portal guide.' });

type Reader = { user_id: string; name: string | null; email: string; last_version: number | null; last_opened_at: string | null; opens: number; banner_dismissed_at: string | null };

export default async function EditGuide({ params, searchParams }: { params: Promise<{ portal: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ portal }, sp] = await Promise.all([params, searchParams]);
  if (!isGuidePortal(portal)) notFound();
  const { user } = await page(`/admin/settings/guides/${portal}`);
  const [g, readers] = await Promise.all([
    door<EditorGuide>(user.id, 'ops_read', 'guide_admin', { portal }),
    door<{ version: number; readers: Reader[] }>(user.id, 'ops_read', 'guide_readers', { portal })]);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings/guides">Guides</Link>} title={g.title}>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href={portal === 'admin' ? GUIDE_PATH.admin : `/admin/guide/${portal}`}>Open the published guide</Link>
    </PageHead>
    <GuideEditor g={g} portal={portal} initial={sp.section ?? null} />
    <Card title="Who opened this guide" testId="guide-readers">
      <p className="small muted">The version each person last opened. Version {readers.version} is published now.</p>
      <Table<Reader> rows={readers.readers} rowKey={(r) => r.user_id} empty="Nobody has opened this guide yet." cols={[
        { key: 'name', label: 'Person', render: (r) => <>{r.name ?? r.email}<br /><span className="small muted">{r.email}</span></> },
        { key: 'last_version', label: 'Version read', render: (r) => (r.last_version === null ? <span className="muted">not opened</span> : r.last_version === readers.version ? `${r.last_version} (current)` : String(r.last_version)) },
        { key: 'last_opened_at', label: 'Last opened', render: (r) => t(r.last_opened_at) },
        { key: 'opens', label: 'Times opened', num: true },
        { key: 'banner_dismissed_at', label: 'Banner dismissed', render: (r) => d(r.banner_dismissed_at) }]} />
    </Card>
  </>);
}
