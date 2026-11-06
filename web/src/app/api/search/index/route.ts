import { getFleet, siteUrl } from '@/lib/site';
import { getArticles, getHubLinks } from '@/features/seo/data';
import { PAGES, PORTALS, type Item } from '@/features/search/index-items';

// The public part of the site search (release 28, B4): every page, the portals' doors, the cars on the site, the places
// and services, and the guides, as one small list the browser searches itself (features/search/SiteSearch.tsx), so
// typing costs the Worker nothing. Rebuilt at most hourly like the home page (an ISR entry, kept at the edge). Public
// data only: what the sitemaps already list.
export const revalidate = 3600;

export async function GET() {
  const [fleet, articles, hubs] = await Promise.all([getFleet().catch(() => []), getArticles().catch(() => []), getHubLinks()]);
  const cars: Item[] = fleet.filter((c) => !c.is_sample).map((c) => ({
    t: [c.year, c.make, c.model].filter(Boolean).join(' '), s: [c.trim, c.colour, c.home_area].filter(Boolean).join(' · ') || undefined,
    h: c.path, g: 'cars' as const, w: [c.class, c.body_style, c.car_code, c.fuel].filter(Boolean).join(' ')
  }));
  const guides: Item[] = articles.map((a) => ({ t: a.title, s: a.description?.slice(0, 90), h: a.path, g: 'guides' as const, w: a.topic ?? undefined }));
  const places: Item[] = [...hubs.places, ...hubs.services, ...hubs.makes, ...hubs.models].map((x) => ({ t: x.name, h: x.path, g: 'places' as const }));
  const seen = new Set<string>();
  const items = [...PORTALS, ...PAGES, ...cars, ...places, ...guides].filter((i) => i.h.startsWith('/') && !seen.has(i.h + i.t) && seen.add(i.h + i.t));
  return new Response(JSON.stringify({ v: 1, site: siteUrl(), items }), {
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'public, max-age=600, s-maxage=3600', 'x-robots-tag': 'noindex' }
  });
}
