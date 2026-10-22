import 'server-only';
import { notFound } from 'next/navigation';
import { tiers } from './data';

// The /buy catch-all is shared with the local SEO release (migration 0095, branch seolocal): /buy/<sale term>/<place> is
// its buying help page, every other /buy address a vehicle page. Two segments whose first is a sale term go to the hub.
// MERGE (with 0095): saleHubMeta and SaleHub become placeHubMeta('sale', ...) and <PlaceHubRoute vertical="sale" .../>
// from '@/features/places/route'. On this branch alone there are no hub pages: a 404.
export async function saleHubParts(seg: string[]): Promise<{ term: string; place: string } | null> {
  if (seg.length !== 2) return null;
  const t = (await tiers()).terms.find((x) => x.kind === 'sale' && x.slug === seg[0]);
  return t ? { term: seg[0]!, place: seg[1]! } : null;
}
export async function saleHubMeta(h: { term: string; place: string }) { void h; notFound(); }
export async function SaleHub(h: { term: string; place: string }) { void h; notFound(); return null; }
