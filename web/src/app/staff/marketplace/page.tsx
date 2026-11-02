import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { MarketplaceView, type MarketplaceData } from '@/features/marketplace/MarketplaceView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Marketplace', path: '/staff/marketplace', noindex: true, description: 'Facebook Marketplace: a kit for every car, what to post or renew today and the inbox replies.' });

// Sales > Marketplace (r27 consolidation; the owner: every Admin upgrade reaches each staff role's portal): Admin's
// Marketing > Marketplace kits for Sales, read only (va_read marketplace, migration 0500: Sales and Admins). The Sales
// Marketing tab builds on this route.
export default async function StaffMarketplace({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/marketplace', ['sales']), searchParams]);
  const data = await read<MarketplaceData>('marketplace');
  return <MarketplaceView data={data} car={sp.car} staff />;
}
