import Link from 'next/link';
import { CarCard } from '@/components/CarCard';
import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { Icon } from '@/components/Icon';
import { JsonLd } from '@/components/JsonLd';
import { absUrl, breadcrumbLd, faqLd, seoMeta, type Trail } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { fill, getClasses, getTokensLite as getTokens, replyText, getSettings, siteUrl } from '@/lib/site';
import { hubCopy, placeLabel } from './copy';
import { hubPath, VERTICAL_ROOT, type Hub } from './data';
import { PlaceLeadForm } from './PlaceLeadForm';
import '@/styles/seo.css';

// One hub page (migration 0095): a place and a term, from real data only. Rentals come first on every page: the
// detailing, body shop and buying pages lead with a rental offer for the same place.
const ROOT_LABEL = { rental: 'Car rental', sale: 'Buying help', detailing: 'Detailing', bodyshop: 'Body shop' } as const;

export async function hubMeta(h: Hub) {
  const t = await getTokens();
  const c = hubCopy(h, { fill: (s) => fill(s, t) });
  // a synonym pointing to another term's page: that page is the canonical one, this one is not indexed
  return seoMeta({ title: c.title, description: c.description, path: h.term.canonical_path ?? h.path, noindex: !h.indexable || !!h.term.canonical_path });
}

export function hubTrail(h: Hub): Trail {
  const root: [string, string] = [ROOT_LABEL[h.term.vertical], VERTICAL_ROOT[h.term.vertical]];
  const anc = h.ancestors.filter((a) => a.kind !== 'region').slice(-3).map((a) => [a.name, hubPath(h.term.vertical, h.term.slug, a.slug)] as [string, string]);
  return [['Home', '/'], root, ...anc, [placeLabel(h)]];
}

export async function HubPage({ h }: { h: Hub }) {
  const [t, classes, s] = await Promise.all([getTokens(), getClasses(), getSettings()]);
  const F = (x: string) => fill(x, t);
  const c = hubCopy(h, { fill: F });
  const labels = Object.fromEntries(classes.map((x) => [x.code, x.label]));
  const where = placeLabel(h);
  const v = h.term.vertical;
  const trail = hubTrail(h);
  const wide = ['country', 'province', 'area', 'region'].includes(h.place.kind);
  const leadKind = (h.term.lead_kind ?? (v === 'rental' && !h.delivery.in_reach && !wide ? 'place_request' : null)) as 'buyer' | 'finance' | 'place_request' | 'detailing' | 'bodyshop' | null;
  const showForm = leadKind && (v !== 'rental' || h.term.served === 'request' || (!h.delivery.in_reach && !wide));
  const rentLinks = h.rental_terms ?? [];
  const graph: object[] = [breadcrumbLd(trail, h.path), ...(c.faq.length ? [faqLd(c.faq)] : [])];
  if (h.cars.length) graph.push({ '@type': 'ItemList', name: c.h1, numberOfItems: h.cars.length,
    itemListElement: h.cars.slice(0, 12).map((x, i) => ({ '@type': 'ListItem', position: i + 1, url: siteUrl() + x.path, name: `${x.year ?? ''} ${x.make} ${x.model}`.trim(), ...(x.cover ? { image: absUrl(x.cover.path) } : {}) })) });
  if ((v === 'detailing' || v === 'bodyshop') && h.service) graph.push({ '@type': 'Service', name: `${h.term.title}`, serviceType: h.service.name, description: h.service.description,
    provider: { '@id': `${siteUrl()}/#business` }, areaServed: { '@type': wide ? 'AdministrativeArea' : 'Place', name: where } });
  const src = h.place.sources;
  return (
    <div className="p-landing p-hub-place" data-page="place-hub" data-vertical={v} data-indexable={h.indexable ? 'yes' : 'no'}>
      <JsonLd graph={graph} />
      <section className="page-head on-dark">
        <div className="wrap">
          <Crumbs trail={trail} />
          <h1 className="d1 landing__h1">{c.h1}</h1>
          {c.lead.map((x, i) => <p key={i} className="lead muted">{x}</p>)}
          {h.disclaimer && <p className="small muted" data-testid="sale-disclaimer">{h.disclaimer}</p>}
          <p className="row landing__cta">
            {v === 'rental' && h.term.served === 'yes'
              ? <><a className="btn btn--primary btn--lg" href="#cars">See the cars</a><Link prefetch={false} className="btn btn--ghost btn--lg" href="/how-it-works">How it works</Link></>
              : <><a className="btn btn--primary btn--lg" href={showForm ? '#request' : '#cars'}>{showForm ? 'Send a request' : 'See the cars'}</a>
                <Link prefetch={false} className="btn btn--ghost btn--lg" href={rentLinks[0]?.path ?? '/cars'}>{v === 'bodyshop' ? 'Rent a replacement car' : 'Rent a car'}</Link></>}
          </p>
        </div>
      </section>

      <section className="facts on-dark" aria-label="At a glance">
        <div className="wrap"><dl className="facts__list">
          {!wide && h.delivery.km !== null && <div><dt>From {h.origin.label === 'our location' ? 'us' : 'central Toronto'}</dt><dd><span className="num">{Math.round(h.delivery.km)}</span> km</dd></div>}
          {v === 'rental' && h.counts.min_daily_cents !== null && <div><dt>From</dt><dd><span className="num">{money(h.counts.min_daily_cents)}</span> a day</dd></div>}
          {!wide && <div><dt>Delivery</dt><dd>{h.delivery.in_reach ? (h.delivery.fee_from_cents ? <>from <span className="num">{money(h.delivery.fee_from_cents)}</span></> : 'Yes') : 'Toronto area only'}</dd></div>}
          {h.airport && !wide && <div><dt>Nearest airport</dt><dd>{h.airport.iata ?? h.airport.name}, <span className="num">{Math.round(h.airport.km)}</span> km</dd></div>}
          {h.service && <div><dt>Price</dt><dd>{h.service.from_price_cents ? <>from <span className="num">{money(h.service.from_price_cents)}</span></> : 'On request'}</dd></div>}
        </dl></div>
      </section>

      {v !== 'rental' && (
        <section className="section--tight on-red cta-band" aria-labelledby="h-rent">
          <div className="wrap cta-band__in">
            <div><h2 className="d2" id="h-rent">{v === 'bodyshop' ? 'Your car is in the shop? Get an insurance replacement rental, delivered.' : v === 'detailing' ? 'Need a car while yours is detailed? Rent one, delivered.' : 'Rent it before you buy it.'}</h2>
              <p className="lead">{v === 'bodyshop' ? 'When your adjuster approves a rental, we can bill your insurance company directly.' : 'Request with no payment, and pay only once we confirm the car and the price.'}</p></div>
            <Link prefetch={false} className="btn btn--light btn--lg" href={rentLinks[0]?.path ?? '/cars'}>{v === 'bodyshop' ? 'Replacement rentals' : 'Rent a car'}</Link>
          </div>
        </section>
      )}

      <section className="section--tight" id="cars" aria-labelledby="h-cars">
        <div className="wrap">
          <div className="section-head"><h2 className="d2" id="h-cars">{v === 'rental' ? (h.term.slug === 'car-rental' ? 'Cars for rent' : `Cars for ${h.term.phrase}`) : 'Cars to rent meanwhile'}</h2>
            <p className="muted small">Live prices before {t.hst} HST, picked up in Toronto or delivered{h.delivery.in_reach || wide ? '' : ' within the Toronto area'}. Each car has its own page, photos and calendar.{h.place.country !== 'CA' ? ' Prices are in Canadian dollars.' : ''}</p></div>
          {h.cars.length
            ? <ul className="fleet-grid fleet-grid--3">{h.cars.slice(0, 12).map((x) => <li key={x.slug}><CarCard c={x} labels={labels} /></li>)}</ul>
            : <p className="alert alert--info"><span>No car matches this right now. <Link prefetch={false} className="link" href="/cars">See every car</Link>.</span></p>}
          <p className="small"><Link prefetch={false} className="link link--go" href="/cars">See every car <Icon name="arrow" /></Link></p>
        </div>
      </section>

      <div className="wrap landing__body">
        {showForm && leadKind && (
          <section className="car-sec" id="request" aria-label="Send a request">
            <PlaceLeadForm kind={leadKind} place={where} term={h.term.slug} reply={replyText(s)} services={h.service ? [h.service.name] : []} />
          </section>
        )}
        {(h.landmarks.length > 0 || (h.airport && !wide)) && (
          <section className="car-sec landing__sec" aria-labelledby="h-around">
            <h2 className="d2" id="h-around">Around {h.place.name}</h2>
            {h.landmarks.length > 0 && <p className="measure">Places nearby: {h.landmarks.map((l) => `${l.name} (${l.km} km)`).join(', ')}.</p>}
            {h.airport && !wide && <p className="measure">The nearest airport is {h.airport.name}{h.airport.iata ? ` (${h.airport.iata})` : ''}, about {Math.round(h.airport.km)} km away.{h.airport.iata === 'YYZ' || h.airport.iata === 'YTZ' ? ' We meet renters there with the car at the time we confirm.' : ''}</p>}
          </section>
        )}
        {c.faq.length > 0 && <section className="car-sec" aria-labelledby="h-faq"><h2 className="d2" id="h-faq">Questions</h2><Faq items={c.faq} /></section>}
        <section className="car-sec landing__links" aria-labelledby="h-more">
          <h2 className="d2" id="h-more">More for {where}</h2>
          <div className="landing__cols">
            {(h.children.length > 0 || (h.gta_members?.length ?? 0) > 0) && <nav aria-label={`Places in ${h.place.name}`}><ul className="linklist">
              {[...(h.gta_members ?? []), ...h.children].slice(0, 30).map((x) => <li key={x.slug}><Link prefetch={false} className="link" href={hubPath(v, h.term.slug, x.slug)}>{h.term.title} in {x.name}</Link></li>)}
            </ul></nav>}
            {h.nearby.length > 0 && <nav aria-label="Nearby places"><ul className="linklist">
              {h.nearby.map((x) => <li key={x.slug}><Link prefetch={false} className="link" href={hubPath(v, h.term.slug, x.slug)}>{h.term.title} in {x.name}</Link></li>)}
            </ul></nav>}
            <nav aria-label="Related searches"><ul className="linklist">
              {[...rentLinks, ...h.related_terms].slice(0, 12).map((x) => <li key={x.path}><Link prefetch={false} className="link" href={x.path}>{x.title} in {h.place.name}</Link></li>)}
              {h.term.landing_path && <li><Link prefetch={false} className="link" href={h.term.landing_path}>{h.term.title} in Toronto</Link></li>}
            </ul></nav>
          </div>
        </section>
        <p className="xs muted" data-testid="place-attribution">
          Place data: {src.osm ? <>GeoNames (CC BY 4.0) and © OpenStreetMap contributors (ODbL)</> : <>GeoNames (CC BY 4.0)</>}{src.census ? ', US Census Bureau' : ''}. <Link prefetch={false} className="link" href="/place-data">Sources and licences</Link>.
        </p>
      </div>
    </div>
  );
}
