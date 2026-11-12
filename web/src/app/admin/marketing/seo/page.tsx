import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { page } from '@/server/admin/api';
import { rpc } from '@/lib/db/repo';
import { SeoActionsView } from '@/features/seo/ActionsView';
import type { SeoData } from '@/features/seo/actions-model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'SEO', path: '/admin/marketing/seo', noindex: true, description: 'Google clicks against the monthly goal, the best queries and pages, pages shown but not clicked, and what is not indexed.' });

// Admin > Marketing > SEO (migration 1860). Sales sees the same page, read only, on Sales > Marketing > SEO.
// 2640: the Google Search Console card (connect, the daily sync, the pages sent to the writer); ?gsc= is the connection's answer.
export default async function AdminSeo({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/marketing/seo'), searchParams]);
  const data = (await rpc('server_seo_actions', { p_user: user.id }, { role: 'service_role' })) as unknown as SeoData;
  return (<>
    <PageHead title="SEO" kicker="Marketing" purpose="Clicks from Google against the monthly goal, what people search, and the pages Google knows but has not indexed. Search Console is read every three hours." />
    <SeoActionsView data={data} gscFlash={sp.gsc} />
  </>);
}
