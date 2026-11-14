import { notFound, permanentRedirect } from 'next/navigation';
import { getHub, type Vertical } from './data';
import { HubPage, hubMeta } from './HubPage';
import { metaOr, titleFromPath } from '@/features/seo/meta-fallback';

// The place and term pages of every family (migration 0095), on demand: never built ahead, never in the page cache,
// kept only in the Worker's edge copy (src/lib/edge/page-cache.ts). The base rental term lives at /car-rental/<place>;
// a term whose landing page covers Toronto sends Toronto's page to that landing page; a synonym sends its page to its
// group's (2402).
async function load(vertical: Vertical, term: string, place: string) {
  if (vertical === 'rental' && term === 'car-rental') permanentRedirect(`/car-rental/${place}`);
  const h = await getHub(vertical, term, place);
  if (!h) notFound();
  // 2402: a synonym of a service group answers 301 with the group's page
  if (h.redirect) permanentRedirect(h.redirect);
  if (vertical === 'rental' && place === 'toronto' && h.term.landing_path) permanentRedirect(h.term.landing_path);
  return h;
}
/** r47: a failed read gives plain metadata instead of failing the page (React #441, features/seo/meta-fallback.ts);
 *  not found and the redirects still pass through. */
export async function placeHubMeta(vertical: Vertical, term: string, place: string) {
  return metaOr(async () => hubMeta(await load(vertical, term, place)), { title: titleFromPath(`/${term}/${place}`) }, (m) => console.warn('place', m));
}
export async function PlaceHubRoute({ vertical, term, place }: { vertical: Vertical; term: string; place: string }) { return <HubPage h={await load(vertical, term, place)} />; }
