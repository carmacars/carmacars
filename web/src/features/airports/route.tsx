import { notFound } from 'next/navigation';
import { SeoShell } from '@/features/seo/Shell';
import { seoMeta, withLanguages } from '@/features/seo/meta';
import { langAlternates } from '@/features/i18n/data';
import { buildDepth } from '@/features/seo/depth';
import { depthCar, getDepthFacts, getPois } from '@/features/seo/depth-data';
import { money } from '@/lib/format';
import { getClasses, getFleet, getSettings, siteUrl } from '@/lib/site';
import { getAirport, getAirports } from './data';
import { airportCopy } from './copy';

export async function airportMeta(code: string) {
  const [a, s] = await Promise.all([getAirport(code), getSettings()]);
  if (!a) return {};
  const c = airportCopy(a, s.brand_name);
  return withLanguages(await seoMeta({ title: c.title, description: c.description, path: `/airport-car-rental/${code}` }), await langAlternates(`/airport-car-rental/${code}`, siteUrl()));
}
export async function AirportRoute({ code }: { code: string }) {
  const a = await getAirport(code);
  if (!a) notFound();
  const [s, fleet, classes, df, pois, all] = await Promise.all([getSettings(), getFleet().catch(() => []), getClasses(), getDepthFacts(), getPois(Number(a.lat), Number(a.lng)), getAirports()]);
  const c = airportCopy(a, s.brand_name);
  const path = `/airport-car-rental/${code}`;
  const depth = buildDepth({ path, facts: df, cars: fleet.filter((x) => !x.is_sample).map(depthCar), pois,
    place: { name: a.name, label: a.name, kind: 'airport', region: 'CA-ON', km: a.km, originLabel: 'our location', inReach: true, reachKm: 0, deliveryFromCents: a.delivery_from_cents } });
  return (
    <SeoShell path={path} testId="airport" trail={[['Home', '/'], ['Airports', '/airport-car-rental'], [a.code]]} h1={c.h1} lead={c.lead}
      facts={[['Airport', a.code], ...(a.delivery_from_cents ? [['Delivery from', money(a.delivery_from_cents)] as [string, string]] : []), ['Handover', 'At the terminal']]}
      cars={fleet} labels={Object.fromEntries(classes.map((x) => [x.code, x.label]))} want={`a car at ${a.code}`} depth={depth} faq={[...c.faq, ...depth.faq].slice(0, 10)}
      ld={[{ '@type': 'Service', name: `Car rental delivered to ${a.name}`, serviceType: 'Car rental', provider: { '@id': `${siteUrl()}/#business` }, areaServed: { '@type': 'Airport', name: a.name, iataCode: a.code } }]}
      links={[...all.filter((x) => x.code !== a.code).map((x) => ({ href: `/airport-car-rental/${x.code.toLowerCase()}`, label: `${x.name} car rental` })), { href: '/delivery', label: 'Delivery and pickup' }, { href: '/events', label: 'Rent a car for Toronto events' }]} />
  );
}
export async function AirportsHub() {
  const [all, s] = await Promise.all([getAirports(), getSettings()]);
  return (
    <SeoShell path="/airport-car-rental" testId="airports" trail={[['Home', '/'], ['Airports']]} h1="Airport car rental, delivered to the terminal"
      lead={[`${s.brand_name} meets you at the terminal with the car, at the standard delivery price.`]}
      links={all.map((x) => ({ href: `/airport-car-rental/${x.code.toLowerCase()}`, label: `${x.name} (${x.code})${x.delivery_from_cents ? `, delivery from ${money(x.delivery_from_cents)}` : ''}` }))} linksTitle="Airports" />
  );
}
