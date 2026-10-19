import Link from 'next/link';
import { notFound } from 'next/navigation';
import { CarCard } from '@/components/CarCard';
import { Crumbs } from '@/components/Crumbs';
import { CtaBand } from '@/components/Blocks';
import { Faq } from '@/components/Faq';
import { Icon } from '@/components/Icon';
import { JsonLd } from '@/components/JsonLd';
import { businessLd } from '@/features/seo/business';
import { getArticles, getSeoPage, paras } from '@/features/seo/data';
import { absUrl, breadcrumbLd, faqLd, type Trail, seoMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { fill, getClasses, getSettings, getTokens, siteUrl } from '@/lib/site';
import OG from '@/features/seo/og-images.json';
import '@/styles/seo.css';

// Landing pages (migration 0061): a place we deliver to or a way of renting, with the live matching cars and prices
// from the database and copy written for that page (Admin > Settings > Search). A page for a use is indexed only
// with enough real matching cars (Program settings seo_landing_min_real_cars); a location page always.
export const revalidate = 3600;
export const dynamicParams = true;
type Params = { params: Promise<{ slug: string }> };

// Rendered on the first visit and kept for the hour (revalidate), not at build time: the build does not wait on the
// database for pages a visitor or the search job renders anyway (deploy run 39289461880 stopped on one).
export async function generateStaticParams() {
  return [];
}
async function load(slug: string) {
  const p = await getSeoPage(slug);
  if (!p) notFound();
  return p;
}
export async function generateMetadata({ params }: Params) {
  const p = await load((await params).slug);
  const t = await getTokens();
  return seoMeta({ title: fill(p.copy.seo_title, t), description: fill(p.copy.meta_description, t), path: p.path, noindex: !p.indexable,
    image: OG.pages.includes(p.slug) ? `${siteUrl()}/og/pages/${p.slug}.png` : null, imageAlt: fill(p.copy.h1, t) });
}

export default async function LandingPage({ params }: Params) {
  const p = await load((await params).slug);
  const [s, t, classes, articles] = await Promise.all([getSettings(), getTokens(), getClasses(), getArticles()]);
  const F = (x: string) => fill(x, t);
  const labels = Object.fromEntries(classes.map((c) => [c.code, c.label]));
  const trail: Trail = [['Home', '/'], ['Car rental', '/car-rental'], [p.name]];
  const faq = p.copy.faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }));
  const reading = articles.filter((a) => (p.kind === 'location' ? ['airports', 'driving', 'trips'] : ['pricing', 'drivers', 'insurance', 'driving']).includes(a.topic ?? '')).slice(0, 3);
  const graph: object[] = [breadcrumbLd(trail, p.path), faqLd(faq),
    { '@type': 'ItemList', name: F(p.copy.h1), numberOfItems: p.cars.length,
      itemListElement: p.cars.slice(0, 12).map((c, i) => ({ '@type': 'ListItem', position: i + 1, url: siteUrl() + c.path, name: `${c.year} ${c.make} ${c.model}`, ...(c.cover ? { image: absUrl(c.cover.path) } : {}) })) }];
  if (p.kind === 'location') graph.push({ ...businessLd(s, siteUrl(), { areas: [p.name.replace(/ \(.*\)$/, '')] }), '@id': `${siteUrl()}/#business` });
  return (
    <div className="p-landing" data-page="landing" data-indexable={p.indexable ? 'yes' : 'no'}>
      <JsonLd graph={graph} />
      <section className="page-head on-dark">
        <div className="wrap">
          <Crumbs trail={trail} />
          <h1 className="d1 landing__h1">{F(p.copy.h1)}</h1>
          {paras(F(p.copy.intro)).map((x, i) => <p key={i} className="lead muted">{x}</p>)}
          <p className="row landing__cta">
            <a className="btn btn--primary btn--lg" href="#cars">See the cars</a>
            <Link prefetch={false} className="btn btn--ghost btn--lg" href="/how-it-works">How it works</Link>
          </p>
        </div>
      </section>
      <section className="facts on-dark" aria-label="Prices here">
        <div className="wrap"><dl className="facts__list">
          <div><dt>Cars</dt><dd className="num">{p.car_count}</dd></div>
          {p.min_daily_cents !== null && <div><dt>From</dt><dd><span className="num">{money(p.min_daily_cents)}</span> a day</dd></div>}
          {p.min_weekly_cents !== null && <div><dt>Weekly from</dt><dd className="num">{money(p.min_weekly_cents)}</dd></div>}
          {p.min_monthly_cents !== null && <div><dt>{F('{{maxDays}} days from')}</dt><dd className="num">{money(p.min_monthly_cents)}</dd></div>}
          {p.min_delivery_cents !== null && <div><dt>{p.airport ? 'Airport delivery from' : 'Delivery from'}</dt><dd><span className="num">{money(p.min_delivery_cents)}</span>{p.delivery_per_km_cents > 0 ? ' plus distance' : ''}{p.airport?.surcharge_cents ? ` plus ${money(p.airport.surcharge_cents)}` : ''}</dd></div>}
        </dl></div>
      </section>

      <section className="section--tight" id="cars" aria-labelledby="h-cars">
        <div className="wrap">
          <div className="section-head"><h2 className="d2" id="h-cars">{p.kind === 'location' ? `Cars for ${p.name.replace(/ \(.*\)$/, '')}` : 'Cars for this'}</h2>
            <p className="muted small">Live prices before {t.hst} HST. Each car has its own page, photos and calendar.{p.distance_km ? ` About ${p.distance_km} km from our location in a straight line.` : ''}</p></div>
          {p.cars.length
            ? <ul className="fleet-grid fleet-grid--3">{p.cars.slice(0, 12).map((c) => <li key={c.slug}><CarCard c={c} labels={labels} /></li>)}</ul>
            : <p className="alert alert--info"><span>No car matches this right now. <Link className="link" href="/cars">See every car</Link>.</span></p>}
          <p className="small"><Link prefetch={false} className="link link--go" href="/cars">{p.car_count > 12 ? `See all ${p.car_count} cars` : 'See every car'} <Icon name="arrow" /></Link></p>
        </div>
      </section>

      <div className="wrap landing__body">
        {p.copy.sections.map((sec, i) => (
          <section key={i} className="car-sec landing__sec" aria-labelledby={`h-s${i}`}>
            <h2 className="d2" id={`h-s${i}`}>{F(sec.heading)}</h2>
            {paras(F(sec.body)).map((x, k) => <p key={k} className="measure">{x}</p>)}
          </section>
        ))}
        {faq.length > 0 && (
          <section className="car-sec" aria-labelledby="h-faq">
            <h2 className="d2" id="h-faq">Questions</h2>
            <Faq items={faq} />
          </section>
        )}
        {(p.nearby.length > 0 || p.other.length > 0 || reading.length > 0) && (
          <section className="car-sec landing__links" aria-labelledby="h-more">
            <h2 className="d2" id="h-more">{p.kind === 'location' ? 'Nearby' : 'More ways to rent'}</h2>
            <div className="landing__cols">
              {p.nearby.length > 0 && <nav aria-label={p.kind === 'location' ? 'Nearby places' : 'Other ways to rent'}><ul className="linklist">{p.nearby.map((n) => <li key={n.slug}><Link prefetch={false} className="link" href={n.path}>{p.kind === 'location' ? `Car rental in ${n.name}` : n.name}</Link></li>)}</ul></nav>}
              {p.other.length > 0 && <nav aria-label="Related"><ul className="linklist">{p.other.map((n) => <li key={n.slug}><Link prefetch={false} className="link" href={n.path}>{n.kind === 'location' ? `Car rental in ${n.name}` : n.name}</Link></li>)}</ul></nav>}
              {reading.length > 0 && <nav aria-label="Guides"><ul className="linklist">{reading.map((a) => <li key={a.slug}><Link prefetch={false} className="link" href={a.path}>{a.title}</Link></li>)}</ul></nav>}
            </div>
          </section>
        )}
      </div>
      <CtaBand h="Pick a car, send a request." p="No payment until we confirm the car and the price." />
    </div>
  );
}
