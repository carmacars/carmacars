import { Suspense } from 'react';
import Link from 'next/link';
import { Crumbs } from '@/components/Crumbs';
import { JsonLd } from '@/components/JsonLd';
import { SlotPicture } from '@/components/Picture';
import { FleetBrowser } from '@/features/fleet/FleetBrowser';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { fill, getClasses, getFacts, getFleet, getSettings, getTokens, siteUrl, slotPhoto } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Fleet']];

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({
    title: fill('Cars to rent in {{city}} from {{minDaily}} a day | {{brand}}', t), path: '/cars',
    description: fill('Cars to rent in {{city}} from {{minDaily}} a day: economy, sedans, SUVs, vans, pickups, convertibles and luxury. Filter by type, seats and price, and check your dates.', t)
  });
}

export default async function Fleet() {
  const [s, f, t, fleet, classes, band, makes] = await Promise.all([getSettings(), getFacts(), getTokens(), getFleet(), getClasses(), slotPhoto('fleet.band'),
    rpc('vehicle_makes', {}) as unknown as Promise<Array<{ slug: string; name: string; path: string; models: number }> | null>]);
  const labels = Object.fromEntries(classes.map((c) => [c.code, c.label]));
  const used = classes.map((c) => c.code).filter((code) => fleet.some((car) => car.classes.includes(code)));
  return (
    <div className="p-fleet" data-page="fleet">
      <JsonLd graph={[breadcrumbLd(trail, '/cars'), { '@type': 'ItemList', name: `${s.brand_name} fleet`, itemListElement: fleet.map((c, i) => ({ '@type': 'ListItem', position: i + 1, url: `${siteUrl()}/cars/${c.slug}`, name: `${c.year} ${c.make} ${c.model}` })) }]} />
      <section className="page-head on-dark">
        <div className="wrap">
          <Crumbs trail={trail} />
          <h1 className="d1">Cars to rent in {s.city}</h1>
          <p className="lead muted">Add your dates to see which cars are free and what the whole trip costs. Pick up, or have it delivered.</p>
        </div>
      </section>
      <Suspense fallback={<div className="wrap section--tight"><ul className="fleet-grid fleet-grid--skeleton" aria-hidden="true">{Array.from({ length: 6 }, (_, i) => <li key={i}><div className="skeleton sk-img"></div></li>)}</ul></div>}>
        <FleetBrowser cars={fleet} labels={labels} classes={used} maxDays={f.max_rental_days} />
      </Suspense>
      {/* every make's vehicle page (migration 0097): its models, years and trims, with our cars */}
      {(makes ?? []).length > 0 && (
        <section className="section--tight" aria-labelledby="h-makes" data-testid="fleet-makes">
          <div className="wrap"><h2 className="d3" id="h-makes">Browse by make</h2>
            <ul className="chips">{(makes ?? []).map((m) => <li key={m.slug}><Link prefetch={false} className="chip" href={m.path}>{m.name}</Link></li>)}</ul>
          </div>
        </section>
      )}
      <section className="band band--short on-dark" aria-label="Ask us">
        <div className="band__media photo fx-drift"><SlotPicture p={band} /></div>
        <div className="wrap band__inner"><div className="band__copy stack">
          <p className="eyebrow">{t.carma}</p><h2 className="d2">Tell us the trip. We’ll suggest the car.</h2>
          <p className="lead">How many people, how far, how long. We suggest a car and send a price.</p>
          <p><Link className="btn btn--light" href="/contact">Ask us</Link></p>
        </div></div>
      </section>
    </div>
  );
}
