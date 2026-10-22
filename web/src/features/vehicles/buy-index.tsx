import Link from 'next/link';
import { JsonLd } from '@/components/JsonLd';
import { Crumbs } from '@/components/Crumbs';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { fill, getTokens } from '@/lib/site';
import '@/styles/vehicles.css';

import 'server-only';

// The /buy tree's start (migration 0097): every make, each with its models, years and trims for buyers.
export async function buyIndexMeta() {
  const t = await getTokens();
  return seoMeta({ title: fill('Buying a car? Specs, recalls and a week-long test drive | {{brand}}', t), path: '/buy',
    description: fill('Every make, model, year and trim: EPA fuel use, dimensions, NHTSA recalls and complaints. Rent the car for a week before you buy it, from {{brand}} in {{city}}.', t) });
}
export async function BuyIndex() {
  const makes = ((await rpc('vehicle_makes', {})) as unknown as Array<{ slug: string; name: string; models: number }> | null) ?? [];
  const trail: Trail = [['Home', '/'], ['Buy']];
  return (
    <div className="p-vehicle" data-page="buy-index">
      <JsonLd graph={[breadcrumbLd(trail, '/buy')]} />
      <section className="page-head on-dark"><div className="wrap"><Crumbs trail={trail} /><h1 className="d1">Buying a car</h1>
        <p className="lead muted">The figures, the recalls and the complaints of every make, model, year and trim, and a week-long test drive: rent the car from us first.</p></div></section>
      <div className="wrap vp-body"><section className="vp-sec" aria-labelledby="h-makes"><h2 className="d3" id="h-makes">Makes</h2>
        <ul className="chips">{makes.map((m) => <li key={m.slug}><Link prefetch={false} className="chip" href={`/buy/${m.slug}`}>{m.name}</Link></li>)}</ul></section></div>
    </div>
  );
}
