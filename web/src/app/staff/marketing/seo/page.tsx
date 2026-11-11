import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { vaPage } from '@/server/va';
import { rpc } from '@/lib/db/repo';
import { SeoActionsView } from '@/features/seo/ActionsView';
import type { SeoData } from '@/features/seo/actions-model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'SEO', path: '/staff/marketing/seo', noindex: true, description: 'Google clicks against the monthly goal, the best queries and pages, pages shown but not clicked, and what is not indexed.' });

// Sales > Marketing > SEO (migration 1860): the Admin's Marketing > SEO page, read only. The database checks the person again.
export default async function StaffSeo() {
  const { user } = await vaPage('/staff/marketing/seo', ['sales']);
  const data = (await rpc('server_seo_actions', { p_user: user.id }, { role: 'service_role' })) as unknown as SeoData;
  return (<>
    <PageHead title="SEO" kicker="Marketing" purpose="Clicks from Google against the monthly goal, what people search, and the pages Google knows but has not indexed. Read only." />
    <SeoActionsView data={data} />
  </>);
}
