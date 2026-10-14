import Link from 'next/link';
import { notFound } from 'next/navigation';
import { CarCard } from '@/components/CarCard';
import { Crumbs } from '@/components/Crumbs';
import { CtaBand } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { fill, getClasses, getSettings, getTokens, photoUrl, siteUrl } from '@/lib/site';
import type { CarRow } from '@/lib/types';

// Model hubs (0022 public_model_hub): every listed car of one make and model, the landing page a
// car's address points to when that car leaves the fleet.
export const revalidate = 3600;
export const dynamicParams = true;
type Hub = { make: string; model: string; path: string; min_daily_rate_cents: number; indexable?: boolean; cars: CarRow[] };
type Params = { params: Promise<{ hub: string }> };

export async function generateStaticParams() {
  const hubs = (await rpc('model_hubs', {})) as unknown as { path: string }[];
  return hubs.map((h) => ({ hub: h.path.replace(/^\/rent\//, '') }));
}
async function load(hub: string) {
  const h = (await rpc('model_hub', { p_hub: hub })) as unknown as Hub | null;
  if (!h) notFound();
  return h;
}
export async function generateMetadata({ params }: Params) {
  const h = await load((await params).hub);
  const t = await getTokens();
  // a model page of sample cars only (vehicles.is_sample, 0035) stays out of search until a real car joins it
  return seoMeta({ title: fill(`Rent a ${h.make} ${h.model} in {{city}} from ${money(h.min_daily_rate_cents)} a day | {{brand}}`, t), path: h.path, noindex: h.indexable === false,
    description: fill(`${h.make} ${h.model} for rent in {{city}} from ${money(h.min_daily_rate_cents)} a day. Pickup or delivery, drivers {{minAge}} and up, request to book with no payment up front.`, t) });
}

export default async function HubPage({ params }: Params) {
  const h = await load((await params).hub);
  const [s, classes] = await Promise.all([getSettings(), getClasses()]);
  const labels = Object.fromEntries(classes.map((c) => [c.code, c.label]));
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [`${h.make} ${h.model}`]];
  const abs = (p: string) => (/^https?:/.test(photoUrl(p)) ? photoUrl(p) : siteUrl() + photoUrl(p));
  return (
    <div className="p-hub">
      <JsonLd graph={[breadcrumbLd(trail, h.path), { '@type': 'ItemList', name: `${h.make} ${h.model} for rent`, itemListElement: h.cars.map((c, i) => ({ '@type': 'ListItem', position: i + 1, url: siteUrl() + c.path, name: `${c.year} ${c.make} ${c.model}`, ...(c.cover ? { image: abs(c.cover.path) } : {}) })) }]} />
      <section className="page-head on-dark"><div className="wrap">
        <Crumbs trail={trail} />
        <h1 className="d1">Rent a {h.make} {h.model} in {s.city}</h1>
        <p className="lead muted">From {money(h.min_daily_rate_cents)} a day. Each car has its own calendar, rates and photos. Pick up, or have it delivered.</p>
      </div></section>
      <section className="section--tight"><div className="wrap">
        <ul className="fleet-grid fleet-grid--3">{h.cars.map((c) => <li key={c.slug}><CarCard c={c} labels={labels} tag="h2" /></li>)}</ul>
        <p className="small"><Link className="link link--go" href="/cars">See every car</Link></p>
      </div></section>
      <CtaBand h="Not the one?" p="Every car in the fleet shows its own dates and prices." />
    </div>
  );
}
