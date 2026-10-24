import Link from 'next/link';
import { AnswerBlock } from '@/components/AnswerBlock';
import { Crumbs } from '@/components/Crumbs';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getSettings, replyText, siteUrl } from '@/lib/site';
import { isAutoService } from './copy';
import { getPlaceRoots, getShopServices, getTerms, hubPath, placesKnown } from './data';
import { PlaceLeadForm } from './PlaceLeadForm';
import '@/styles/seo.css';

// /detailing and /body-shop (migration 0095): the services CarmaCars offers, a starting price only when an Admin set
// one, the area we work in, a request, and rentals first: a car to drive while yours is with us.
// The hubs' titles name what they cover: the place page of their first term in Toronto (/detailing/car-detailing/toronto,
// /body-shop/auto-body-shop/toronto) is titled "<Term> in Toronto | CarmaCars", and two pages never share a title.
const COPY = {
  detailing: { path: '/detailing', label: 'Detailing', title: 'Car Detailing in Toronto: Ceramic, Tint, PPF | CarmaCars', h1: 'Car detailing in Toronto',
    lead: 'Interior and exterior detailing, paint correction and ceramic coating, mobile detailing at your place, window tint, PPF and wraps.',
    rent: ['Need a car while yours is detailed? Rent one, delivered.', 'Request with no payment, and pay only once we confirm the car and the price.', '/car-rental/car-rental-delivery/toronto'],
    terms: ['car-detailing', 'mobile-detailing', 'ceramic-coating', 'paint-correction', 'window-tint', 'paint-protection-film', 'interior-detailing', 'car-wrap'] },
  bodyshop: { path: '/body-shop', label: 'Body shop', title: 'Auto Body Shop in Toronto: Collision, Dents, Paint | CarmaCars', h1: 'Auto body shop in Toronto',
    lead: 'Collision and accident repair, dents and scratches, bumpers, painting and rust repair, and windshield repair.',
    rent: ['Your car is in the shop? Get an insurance replacement rental, delivered.', 'When your adjuster approves a rental, we can bill your insurance company directly.', '/car-rental/insurance-replacement'],
    terms: ['collision-repair', 'auto-body-shop', 'dent-repair', 'paintless-dent-repair', 'bumper-repair', 'scratch-repair', 'car-painting', 'windshield-repair'] }
} as const;

export async function serviceMeta(v: 'detailing' | 'bodyshop') {
  const d = await getShopServices(v);
  const c = COPY[v];
  const names = d.services.map((x) => x.name.toLowerCase()).join(', ');
  return seoMeta({ title: c.title, path: c.path, description: `${c.h1} by CarmaCars: ${names}. Price on request, and a rental car delivered while yours is with us.`.slice(0, 165) });
}

export async function ServicePage({ v }: { v: 'detailing' | 'bodyshop' }) {
  const [d, roots, s, known, terms] = await Promise.all([getShopServices(v), getPlaceRoots(), getSettings(), placesKnown(['toronto']).catch(() => [] as string[]), getTerms()]);
  // 0121: the mechanical work we arrange with a trusted shop (never ours), linked from the body shop page
  const arranged = v === 'bodyshop' ? terms.filter(isAutoService) : [];
  // the place pages for Toronto only once the places are loaded (an empty places table has none)
  const home = known.includes('toronto') ? 'toronto' : null;
  const c = COPY[v];
  const trail: Trail = [['Home', '/'], [c.label]];
  const vert = v === 'bodyshop' ? 'bodyshop' : 'detailing';
  const graph = [breadcrumbLd(trail, c.path), { '@type': 'ItemList', name: c.h1, itemListElement: d.services.map((x, i) => ({ '@type': 'ListItem', position: i + 1,
    item: { '@type': 'Service', name: x.name, description: x.description, provider: { '@id': `${siteUrl()}/#business` }, areaServed: { '@type': 'City', name: 'Toronto' },
      ...(x.from_price_cents ? { offers: { '@type': 'Offer', priceCurrency: 'CAD', price: (x.from_price_cents / 100).toFixed(2) } } : {}) } })) }];
  return (
    <div className="p-landing p-service" data-page={`service-${v}`}>
      <JsonLd graph={graph} />
      <section className="page-head on-dark"><div className="wrap">
        <Crumbs trail={trail} />
        <h1 className="d1 landing__h1">{c.h1}</h1>
        <p className="lead muted">{c.lead} We work in the Toronto area, within about {d.reach_km} km of {d.origin.label === 'our location' ? 'our location' : 'central Toronto'}.</p>
        <p className="row landing__cta"><a className="btn btn--primary btn--lg" href="#request">Send a request</a><Link prefetch={false} className="btn btn--ghost btn--lg" href={c.rent[2]}>Rent a car meanwhile</Link></p>
      </div></section>
      {(() => {
        const priced = d.services.map((x) => x.from_price_cents).filter((x): x is number => !!x);
        const price = priced.length ? `From ${money(Math.min(...priced))}; other work priced on request` : 'Price on request, for your car and the work';
        const names = d.services.map((x) => x.name.toLowerCase());
        return <AnswerBlock lead={`${s.brand_name} offers ${c.label.toLowerCase()} in Toronto: ${names.join(', ')}. ${price}. We work within about ${d.reach_km} km of ${d.origin.label === 'our location' ? 'our location' : 'central Toronto'}, and can deliver a rental car while yours is with us. Send a request below${s.phone_display ? ` or call ${s.phone_display}` : ''}.`}
          rows={[['Services', d.services.map((x) => x.name).join(', ')], ['Price', price], ['Where', `The Toronto area, within about ${d.reach_km} km`], ['How to book', 'Send a request with your car and the work. We reply with a price before any work.'],
            ...(s.phone_display ? [['Phone', s.phone_display] as [string, string]] : [])]} />;
      })()}
      <section className="section--tight on-red cta-band" aria-labelledby="h-rent">
        <div className="wrap cta-band__in"><div><h2 className="d2" id="h-rent">{c.rent[0]}</h2><p className="lead">{c.rent[1]}</p></div>
          <Link prefetch={false} className="btn btn--light btn--lg" href={c.rent[2]}>Rent a car</Link></div>
      </section>
      <section className="section--tight" aria-labelledby="h-svc"><div className="wrap stack">
        <h2 className="d2" id="h-svc">What we do</h2>
        <ul className="hub-grid">{d.services.map((x) => (
          <li key={x.code}><div className="hub-card"><h3>{x.name}</h3><p>{x.description}</p>
            <p>{x.from_price_cents ? <>From <span className="num">{money(x.from_price_cents)}</span></> : 'Price on request'}</p>
            {home && x.terms.length > 0 && <p>{x.terms.slice(0, 4).map((t, i) => <span key={t.slug}>{i > 0 ? ', ' : ''}<Link prefetch={false} className="link" href={hubPath(vert, t.slug, home)}>{t.title} in Toronto</Link></span>)}</p>}
          </div></li>))}</ul>
      </div></section>
      {home && arranged.length > 0 && (
        <section className="section--tight" aria-labelledby="h-arranged"><div className="wrap stack">
          <h2 className="d2" id="h-arranged">Mechanical work we arrange</h2>
          <p className="measure">CarmaCars does not do mechanical work. Request it and we arrange it with a trusted shop or connect you with one, and you can rent a car from us while yours is in.</p>
          <nav aria-label="Mechanical work we arrange in Toronto"><ul className="linklist" data-testid="arranged-terms">
            {arranged.map((t) => <li key={t.slug}><Link prefetch={false} className="link" href={hubPath('bodyshop', t.slug, home)}>{t.title} in Toronto</Link></li>)}
          </ul></nav>
        </div></section>
      )}
      <div className="wrap landing__body">
        <section className="car-sec" id="request" aria-label="Send a request">
          <PlaceLeadForm kind={v} services={d.services.map((x) => x.name)} reply={replyText(s)} />
        </section>
        <section className="car-sec landing__links" aria-labelledby="h-where">
          <h2 className="d2" id="h-where">Where we work</h2>
          <div className="landing__cols">
            {home && <nav aria-label="Services in Toronto"><ul className="linklist">{d.services.flatMap((x) => x.terms).slice(0, 12).map((t) => <li key={t.slug}><Link prefetch={false} className="link" href={hubPath(vert, t.slug, home)}>{t.title} in Toronto</Link></li>)}</ul></nav>}
            {roots.cities.length > 0 && <nav aria-label="Places near Toronto"><ul className="linklist">{roots.cities.slice(0, 12).map((p) => <li key={p.slug}><Link prefetch={false} className="link" href={hubPath(vert, c.terms[0], p.slug)}>{c.label} in {p.name}</Link></li>)}</ul></nav>}
          </div>
        </section>
      </div>
    </div>
  );
}
