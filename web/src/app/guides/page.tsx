import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { getArticles } from '@/features/seo/data';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { fill, getTokens, siteUrl } from '@/lib/site';
import '@/styles/seo.css';

// The guides (migration 0061): practical articles for renting a car in Toronto, edited in Admin > Settings > Search.
export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Guides']];
const TOPIC: Record<string, string> = { drivers: 'Drivers', driving: 'Driving', airports: 'Airports', pricing: 'Prices', insurance: 'Repairs and claims', trips: 'Road trips' };

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Car Rental Guides for Toronto | {{brand}}', t), path: '/guides',
    description: fill('Practical guides to renting a car in Toronto: young drivers, 407 ETR tolls, airport pickup, monthly rentals, winter driving and road trips.', t) });
}

export default async function Guides() {
  const [list, t] = await Promise.all([getArticles(), getTokens()]);
  return (
    <div className="p-guides">
      <JsonLd graph={[breadcrumbLd(trail, '/guides'), { '@type': 'ItemList', name: 'Guides', itemListElement: list.map((a, i) => ({ '@type': 'ListItem', position: i + 1, url: siteUrl() + a.path, name: a.title })) }]} />
      <PageHead trail={trail} h1="Guides to renting in Toronto" lead="Straight answers to the questions renters ask us most: who can rent, what it costs, and how to get around." />
      <section className="section--tight"><div className="wrap">
        <ul className="art-list">{list.map((a) => (
          <li key={a.slug}><Link prefetch={false} href={a.path}>
            {a.topic && <span className="art-kicker">{TOPIC[a.topic] ?? a.topic}</span>}
            <h2>{fill(a.title, t)}</h2>
            <p>{fill(a.summary ?? a.description, t)}</p>
          </Link></li>))}</ul>
      </div></section>
      <CtaBand h="Ready to rent?" p="Pick a car and send a request. No payment until we confirm." />
    </div>
  );
}
