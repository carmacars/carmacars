import { PlaceHubRoute, placeHubMeta } from '@/features/places/route';

// A place and term page (migration 0095): /body-shop/<term>/<place>. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ term: string; place: string }> };

export async function generateMetadata({ params }: Params) {
  const p = await params;
  return placeHubMeta('bodyshop', p.term, p.place);
}
export default async function Page({ params }: Params) {
  const p = await params;
  return <PlaceHubRoute vertical="bodyshop" term={p.term} place={p.place} />;
}
