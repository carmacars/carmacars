import { PlaceHubRoute, placeHubMeta } from '@/features/places/route';

// A place and term page (migration 0095): /car-rental/<term>/<place>. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string; place: string }> };

export async function generateMetadata({ params }: Params) {
  const p = await params;
  return placeHubMeta('rental', p.slug, p.place);
}
export default async function Page({ params }: Params) {
  const p = await params;
  return <PlaceHubRoute vertical="rental" term={p.slug} place={p.place} />;
}
