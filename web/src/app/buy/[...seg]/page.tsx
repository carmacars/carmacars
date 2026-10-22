import { BUY, TwinView, twinMeta, twinPage } from '@/features/vehicles/twin';

// The for-sale twin of every vehicle page (migration 0092): /buy/<make>[/<model>[/<year>[/<trim>[/<place>[/<colour>]]]]]
// and /buy/.../<trim>/colour/<colour>. Rendered on demand with no ISR entry (no KV write per page); the Worker's edge
// copy keeps it for 6 hours (src/lib/edge/page-cache.ts, PROGRAMMATIC).
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ seg: string[] }> };

export async function generateMetadata({ params }: Params) {
  return twinMeta(await twinPage(BUY, (await params).seg));
}
export default async function Page({ params }: Params) {
  return <TwinView {...await twinPage(BUY, (await params).seg)} />;
}
