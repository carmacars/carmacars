import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { MarketplaceView, type MarketplaceData } from '@/features/marketplace/MarketplaceView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Marketplace', path: '/admin/marketing/marketplace', noindex: true, description: 'Facebook Marketplace: a kit for every car, what to post or renew today, the inbox replies, and the log.' });

// Admin > Marketing > Marketplace (migration 0410; docs/runbooks/marketplace.md): the read, then the page body.
export default async function Marketplace({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/marketplace'), searchParams]);
  const data = await read<MarketplaceData>('marketplace');
  return <MarketplaceView data={data} car={sp.car} />;
}
