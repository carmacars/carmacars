import { notFound } from 'next/navigation';
import { PlaceHubRoute, placeHubMeta } from '@/features/places/route';

// /buy/<term>/<place>: the buying help pages of migration 0095 (cars for sale, financing, leasing: CarmaCars does not
// sell, lend or lease; the page says so, offers a rental and takes a request). The vehicle pages' /buy tree (branch
// vehiclepages) shares this catch-all: when both are merged, it tries a sale term first (two segments whose first is a
// sale term), then the vehicle pages.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ seg: string[] }> };

const parts = (seg: string[]) => (seg.length === 2 ? { term: seg[0]!, place: seg[1]! } : null);
export async function generateMetadata({ params }: Params) {
  const p = parts((await params).seg);
  if (!p) notFound();
  return placeHubMeta('sale', p.term, p.place);
}
export default async function Page({ params }: Params) {
  const p = parts((await params).seg);
  if (!p) notFound();
  return <PlaceHubRoute vertical="sale" term={p.term} place={p.place} />;
}
