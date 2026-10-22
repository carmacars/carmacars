import 'server-only';
import { PlaceHubRoute, placeHubMeta } from '@/features/places/route';
import { tiers } from './data';

// The /buy catch-all is shared with the local SEO release (migration 0095): /buy/<sale term>/<place> is its buying help
// page, every other /buy address a vehicle page. Two segments whose first is a sale term go to the hub.
export async function saleHubParts(seg: string[]): Promise<{ term: string; place: string } | null> {
  if (seg.length !== 2) return null;
  const t = (await tiers()).terms.find((x) => x.kind === 'sale' && x.slug === seg[0]);
  return t ? { term: seg[0]!, place: seg[1]! } : null;
}
export const saleHubMeta = (h: { term: string; place: string }) => placeHubMeta('sale', h.term, h.place);
export const SaleHub = (h: { term: string; place: string }) => PlaceHubRoute({ vertical: 'sale', term: h.term, place: h.place });
