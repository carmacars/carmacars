import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { MarketingView, type MarketingData } from '@/features/marketplace/MarketingView';
import { scenePhotos } from '@/server/marketing-photos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Marketing', path: '/staff/marketing', noindex: true, description: 'Facebook Marketplace from your own profile: today\'s posts, your own copy of each car, the replies and your log.' });

// Sales > Marketing (migration 0510; docs/runbooks/marketplace.md): the Marketplace tool for each salesperson's own Facebook
// profile, with no ad or copy posted twice across the team.
export default async function StaffMarketing({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, roles, user, aal }, sp] = await Promise.all([vaPage('/staff/marketing', ['sales']), searchParams]);
  const data = await read<MarketingData>('mp_team');
  const path = roles.sales_work_mode === 'in_person' ? 'sales_in_person' : 'sales_remote';
  return <MarketingView data={data} car={sp.car} academyHref={`/staff/academy/${path}/marketplace-with-claude`}
    scenes={(v) => scenePhotos(user.id, v, aal).then((x) => x.length > 0).catch(() => false)} />;
}
