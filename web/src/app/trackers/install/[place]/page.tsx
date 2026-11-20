import { notFound } from 'next/navigation';
import { seoMeta } from '@/features/seo/meta';
import { metaOr, titleFromPath } from '@/features/seo/meta-fallback';
import { getHub } from '@/features/places/data';
import { KitFacts, KitSection } from '@/features/seo/kit/Kit';
import { TrackerTemplate, loadTracker, trackerFacts } from '@/features/trackers/TrackerPage';
import { everyone, monthlySentence, offer, PriceSentence } from '@/features/trackers/pages';
import { money } from '@/lib/format';
import { siteUrl } from '@/lib/site';

// "GPS tracker install in <place>" (release 48): one page per Ontario place, gated like the other place pages. The place
// comes from the place data of migration 0095 (public.place_hub of the car rental term): a region that is off answers
// 404; a place beyond our reach, or one the place pages do not index, is noindex. The page's own facts are the place's:
// how far it is from our location, the nearest places, and the same price and waitlist as everywhere.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ place: string }> };

async function load(place: string) {
  if (!/^[a-z0-9-]{2,80}$/.test(place)) notFound();
  const h = await getHub('rental', 'car-rental', place).catch(() => null);
  if (!h || h.redirect || !h.place) notFound();
  return h;
}

export async function generateMetadata({ params }: Params) {
  const { place } = await params;
  return metaOr(async () => {
    const [x, h] = await Promise.all([trackerFacts(), load(place)]);
    if (!x) return {};
    // the title stays within 70 characters for a long place name
    const where = `${h.place.name}${h.place.region ? `, ${h.place.region.replace(/^CA-/, '')}` : ''}`;
    const title = [`GPS Tracker and Kill Switch Install in ${where} | ${x.f.brand}`, `GPS Tracker Install in ${where} | ${x.f.brand}`, `GPS Tracker Install in ${h.place.name}`].find((t) => t.length <= 70) ?? `GPS Tracker Install in ${h.place.name}`.slice(0, 70);
    return seoMeta({ title,
      description: `${x.f.name} installed for car owners in ${h.place.name}: live GPS, a remote kill switch, door locking and an alarm. ${offer(x.f)}.`.slice(0, 170),
      path: `/trackers/install/${h.place.slug}`, noindex: !(h.indexable && h.delivery.in_reach) });
  }, { title: titleFromPath(`/trackers/install/${place}`) }, (m) => console.warn('tracker place', m));
}

export default async function Page({ params }: Params) {
  const { place } = await params;
  const [{ f }, h] = await Promise.all([loadTracker(), load(place)]);
  const p = h.place;
  const km = h.delivery.km !== null && h.delivery.km !== undefined ? Math.round(h.delivery.km) : null;
  const near = h.nearby.filter((n) => n.kind === 'city' || n.kind === 'neighbourhood' || n.kind === 'area').slice(0, 12);
  const region = p.region_name ?? 'Ontario';
  const path = `/trackers/install/${p.slug}`;
  return (
    <TrackerTemplate path={path} testId="tracker-install-place" city={p.name} facts={f} kicker={`Install in ${p.name}`} icon="wrench"
      trail={[['Home', '/'], [f.name, '/trackers'], ['Install near you', '/trackers/install'], [p.name]]}
      h1={`GPS tracker and kill switch install in ${p.name}`}
      answer={`${f.brand} installs the ${f.name} for car owners in ${p.name}, ${region}${km !== null ? `, about ${km} km from us` : ''}. Live GPS, a remote kill switch, door locking and an alarm. ${PriceSentence(f)}. ${everyone(f)}.`}
      own={{ h: `How an install in ${p.name} goes`, p: h.delivery.in_reach ? `${p.name} is inside the area we serve.` : `${p.name} is outside the area we drive to today: you bring the car to us, or we tell you when we come your way.`,
        steps: [['Tell us where the car is', `Join the waitlist with ${p.name} as your city.`], ['We agree the day and place', h.delivery.in_reach ? `In ${p.name} or at our location, whichever suits you.` : 'At our location.'],
          ['The tracker goes in', 'Out of sight, wired to the starter, and tested with you.'], ['Your car is on the map', 'From that minute, on your phone.']] }}
      faq={[
        { question: `How much is a GPS tracker install in ${p.name}?`, answer: `${f.installCents ? `${money(f.installCents)} once per car` : 'The install is quoted for your car'}. ${PriceSentence(f)}. Prices are before ${f.hst} HST.` },
        { question: `Do you come to ${p.name}?`, answer: h.delivery.in_reach ? `Yes. ${p.name} is inside the area we serve${km !== null ? `, about ${km} km from us` : ''}. We agree the place with you.` : `${p.name} is beyond the area we drive to today. Bring the car to us, or join the waitlist and we tell you when we come your way.` },
        { question: 'Can I book an install today?', answer: f.available ? 'Yes. Send the order request and we agree the day.' : `${f.launchNote}. Join the waitlist or pre-order: you hear first, and nothing is charged until we confirm your install.` },
        { question: 'What does the tracker do?', answer: 'It shows the car live on a map, keeps a parked car from being started (a starter interrupt), locks and releases the doors, sounds the alarm, and keeps each trip with its route and times.' }]}
      lead={['Installed', 'Kill switch', 'Live GPS']}
      places={near.map((n) => ({ href: `/trackers/install/${n.slug}`, label: `Tracker install in ${n.name}` }))} placesTitle={`Near ${p.name}`}
      extraLd={[{ '@type': 'Service', name: `GPS tracker and kill switch installation in ${p.name}`, serviceType: 'GPS tracker installation', url: siteUrl() + path, provider: { '@id': `${siteUrl()}/#business` },
        areaServed: { '@type': p.kind === 'city' ? 'City' : 'Place', name: p.name, ...(p.lat !== null && p.lng !== null ? { geo: { '@type': 'GeoCoordinates', latitude: p.lat, longitude: p.lng } } : {}) } }]}
      placeNote={<KitSection id="place" kicker={region} h={`${p.name} at a glance`}>
        <KitFacts rows={[['Place', `${p.name}, ${region}`], ['Distance from us', km !== null ? `About ${km} km in a straight line` : null], ['Inside the area we serve', h.delivery.in_reach ? 'Yes' : 'You bring the car to us'],
          ['Nearest airport', h.airport ? `${h.airport.name}, about ${Math.round(h.airport.km)} km` : null], ['The tracker', PriceSentence(f)], ['Monthly service', monthlySentence(f)], ['Install', f.installCents ? `${money(f.installCents)} once per car` : null]]} />
      </KitSection>} />
  );
}
