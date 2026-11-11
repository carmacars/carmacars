import { notFound } from 'next/navigation';
import { SeoShell } from '@/features/seo/Shell';
import { seoMeta, withLanguages } from '@/features/seo/meta';
import { langAlternates } from '@/features/i18n/data';
import { buildDepth } from '@/features/seo/depth';
import { depthCar, getDepthFacts, getPois } from '@/features/seo/depth-data';
import { getClasses, getFleet, getSettings, siteUrl } from '@/lib/site';
import { rpc } from '@/lib/db/repo';
import { getEvent, getEvents } from './data';
import { eventCopy } from './copy';

// An event page (release 36, part 5): the event's row, the cars ready to book, getting there and parking near the
// venue (place_pois), the requirements, real reviews, questions. Edge copy only.
export async function eventMeta(slug: string) {
  const [e, s] = await Promise.all([getEvent(slug), getSettings()]);
  if (!e) return {};
  const c = eventCopy(e, s.brand_name);
  return withLanguages(await seoMeta({ title: c.title, description: c.description, path: `/events/${e.slug}` }), await langAlternates(`/events/${e.slug}`, siteUrl()));
}
export async function EventPage({ slug }: { slug: string }) {
  const e = await getEvent(slug);
  if (!e) notFound();
  const [s, fleet, classes, df, pois, all, dl] = await Promise.all([getSettings(), getFleet().catch(() => []), getClasses(), getDepthFacts(), getPois(Number(e.lat), Number(e.lng)), getEvents(),
    (rpc('delivery_to_point', { p_lat: Number(e.lat), p_lng: Number(e.lng) }) as unknown as Promise<{ km: number | null; in_reach?: boolean; reach_km?: number; fee_from_cents?: number | null }>).catch(() => null)]);
  const c = eventCopy(e, s.brand_name);
  const km = dl?.km ?? null;
  const path = `/events/${e.slug}`;
  const depth = buildDepth({ path, facts: df, cars: fleet.filter((x) => !x.is_sample).map(depthCar), place: { name: e.venue, label: e.venue, kind: 'venue', region: 'CA-ON', km, originLabel: 'our location',
    inReach: !!dl?.in_reach, reachKm: dl?.reach_km ?? 0, deliveryFromCents: dl?.fee_from_cents ?? null }, pois });
  const ld = { '@type': 'Event', name: e.name, description: e.summary, location: { '@type': 'Place', name: e.venue, address: e.venue_address ?? e.city, geo: { '@type': 'GeoCoordinates', latitude: Number(e.lat), longitude: Number(e.lng) } },
    ...(c.when.announced && e.starts_on ? { startDate: e.starts_on, endDate: e.ends_on ?? e.starts_on, eventStatus: 'https://schema.org/EventScheduled', eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
      organizer: { '@type': 'Organization', name: e.source_name, url: e.source_url } } : {}) };
  return (
    <SeoShell path={path} testId="event" trail={[['Home', '/'], ['Events', '/events'], [e.name]]} h1={c.h1} lead={c.lead}
      facts={[['When', c.when.text.replace(/^usually /, 'Usually ')], ['Venue', e.venue], ...(km !== null ? [['From us', `${Math.round(km)} km`] as [string, string]] : [])]}
      cars={fleet} labels={Object.fromEntries(classes.map((x) => [x.code, x.label]))} want={`a car for ${e.name}`} depth={depth} faq={[...c.faq, ...depth.faq].slice(0, 10)}
      ld={c.when.announced ? [ld] : []} links={all.filter((x) => x.slug !== e.slug).slice(0, 12).map((x) => ({ href: `/events/${x.slug}`, label: `Rent a car for ${x.name}` }))} linksTitle="More events">
      <p className="xs muted" data-testid="event-source">Event details: <a className="link" href={e.source_url} rel="nofollow noopener" target="_blank">{e.source_name}</a>.</p>
    </SeoShell>
  );
}
export async function EventsHub() {
  const [all, s] = await Promise.all([getEvents(), getSettings()]);
  return (
    <SeoShell path="/events" testId="events" trail={[['Home', '/'], ['Events']]} h1="Rent a car for Toronto events"
      lead={[`Festivals, games, concerts and shows across Toronto and the GTA. ${s.brand_name} delivers the car to your address, a hotel or the airport, or you pick it up in Toronto.`]}
      links={all.map((x) => ({ href: `/events/${x.slug}`, label: `${x.name}, ${x.usual_months.toLowerCase()}` }))} linksTitle="Events" />
  );
}
