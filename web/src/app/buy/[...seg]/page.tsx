import { SaleHub, saleHubMeta, saleHubParts } from '@/features/vehicles/sale-hub';
import { BUY, TwinView, twinMeta, twinPage } from '@/features/vehicles/twin';

// /buy: the buying help pages of the local SEO release first (/buy/<sale term>/<place>, migration 0095), then the
// for-sale twin of every vehicle page (migration 0097): /buy/<make>[/<model>[/<year>[/<trim>[/<place>[/<colour>]]]]] and
// /buy/.../<trim>/colour/<colour>. Rendered on demand with no ISR entry (no KV write per page); the Worker's edge copy
// keeps it for 6 hours (src/lib/edge/page-cache.ts, PROGRAMMATIC).
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ seg: string[] }> };

export async function generateMetadata({ params }: Params) {
  const seg = (await params).seg;
  const hub = await saleHubParts(seg);
  if (hub) return saleHubMeta(hub);
  return twinMeta(await twinPage(BUY, seg));
}
export default async function Page({ params }: Params) {
  const seg = (await params).seg;
  const hub = await saleHubParts(seg);
  if (hub) return <SaleHub {...hub} />;
  return <TwinView {...await twinPage(BUY, seg)} />;
}
