import { notFound, permanentRedirect } from 'next/navigation';
import { getHub, type Vertical } from './data';
import { HubPage, hubMeta } from './HubPage';

// The place and term pages of every family (migration 0095), on demand: never built ahead, never in the page cache,
// kept only in the Worker's edge copy (src/lib/edge/page-cache.ts). The base rental term lives at /car-rental/<place>;
// a term whose landing page covers Toronto sends Toronto's page to that landing page.
async function load(vertical: Vertical, term: string, place: string) {
  if (vertical === 'rental' && term === 'car-rental') permanentRedirect(`/car-rental/${place}`);
  const h = await getHub(vertical, term, place);
  if (!h) notFound();
  if (vertical === 'rental' && place === 'toronto' && h.term.landing_path) permanentRedirect(h.term.landing_path);
  return h;
}
export async function placeHubMeta(vertical: Vertical, term: string, place: string) { return hubMeta(await load(vertical, term, place)); }
export async function PlaceHubRoute({ vertical, term, place }: { vertical: Vertical; term: string; place: string }) { return <HubPage h={await load(vertical, term, place)} />; }
