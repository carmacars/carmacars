import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { getSeoPages } from '@/features/seo/data';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { fill, getTokens, siteUrl } from '@/lib/site';
import '@/styles/seo.css';

// The hub of the landing pages (migration 0061): every place we deliver to and every way of renting, with the live
// number of cars and the lowest price of each. Only pages that may be indexed are listed.
export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Car rental']];

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Car Rental in Toronto and the GTA | {{brand}}', t), path: '/car-rental',
    description: fill('Car rental across Toronto and the GTA: delivery to your area or airport, and rentals by the week, month or weekend. Live prices from {{minDaily}} a day.', t) });
}

export default async function CarRentalHub() {
  const [pages, t] = await Promise.all([getSeoPages(), getTokens()]);
  const live = pages.filter((p) => p.indexable);
  const places = live.filter((p) => p.kind === 'location');
  const uses = live.filter((p) => p.kind === 'use');
  const card = (p: (typeof live)[number]) => (
    <li key={p.slug}><Link prefetch={false} className="hub-card" href={p.path}>
      <h3>{p.kind === 'location' ? `Car rental in ${p.name}` : p.name}</h3>
      <p>{fill(p.summary, t)}</p>
      <p>{p.car_count} {p.car_count === 1 ? 'car' : 'cars'}{p.min_daily_cents !== null ? <>, from <span className="num">{money(p.min_daily_cents)}</span> a day</> : null}</p>
    </Link></li>);
  return (
    <div className="p-hub-seo">
      <JsonLd graph={[breadcrumbLd(trail, '/car-rental'), { '@type': 'ItemList', name: 'Car rental in Toronto and the GTA',
        itemListElement: live.map((p, i) => ({ '@type': 'ListItem', position: i + 1, url: siteUrl() + p.path, name: p.name })) }]} />
      <PageHead trail={trail} h1="Car rental in Toronto and the GTA" lead={fill('We deliver to any address in the city and the suburbs, and to {{airports}}. Pick your area or the way you want to rent.', t)} />
      <section className="section--tight" aria-labelledby="h-places"><div className="wrap stack">
        <h2 className="d2" id="h-places">Where we deliver</h2>
        <ul className="hub-grid">{places.map(card)}</ul>
      </div></section>
      {uses.length > 0 && <section className="section--tight on-grey" aria-labelledby="h-uses"><div className="wrap stack">
        <h2 className="d2" id="h-uses">Ways to rent</h2>
        <ul className="hub-grid">{uses.map(card)}</ul>
      </div></section>}
      <CtaBand h="Not sure where to start?" p="Every car shows its own dates, prices and delivery fee." />
    </div>
  );
}
