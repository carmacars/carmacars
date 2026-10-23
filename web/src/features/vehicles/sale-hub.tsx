import 'server-only';
import { getHub } from '@/features/places/data';
import { PlaceHubRoute, placeHubMeta } from '@/features/places/route';
import { tiers } from './data';

// The /buy catch-all is shared with the local SEO release (migration 0095): /buy/<sale term>/<place> is its buying help
// page, every other /buy address a vehicle page. Two segments whose first is a sale term go to the hub.
export async function saleHubParts(seg: string[]): Promise<{ term: string; place: string } | null> {
  if (seg.length !== 2) return null;
  const terms = (await tiers()).terms;
  if (terms.some((x) => x.kind === 'sale' && x.slug === seg[0])) return { term: seg[0]!, place: seg[1]! };
  // a synonym of a sale term (0115: "car loan" for auto loans) is served like the rental ones, with its term's page as
  // canonical, when that term has its pages; the synonyms are not in the tiers (they have no vehicle tree of their own)
  const h = await getHub('sale', seg[0]!, seg[1]!);
  const own = h?.term.canonical_path?.split('/')[2];
  return own && terms.some((x) => x.kind === 'sale' && x.slug === own) ? { term: seg[0]!, place: seg[1]! } : null;
}
export const saleHubMeta = (h: { term: string; place: string }) => placeHubMeta('sale', h.term, h.place);
export const SaleHub = (h: { term: string; place: string }) => PlaceHubRoute({ vertical: 'sale', term: h.term, place: h.place });
