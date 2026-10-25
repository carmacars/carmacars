import Link from 'next/link';
import { CarCard } from '@/components/CarCard';
import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { studioName } from '@/features/car/studio';
import type { Trail } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { siteUrl } from '@/lib/site';
import type { CarRow } from '@/lib/types';
import { Availability } from './Availability';
import { photoLd, StockFigure, stockAlt, stockNote } from './photo';
import type { StockPhoto } from './stock-photos';
import { type Spec, type YearRow, dollars, fuelWord, list, paintFor, priceBasis, shapeFor, tripCosts, ratingText } from './content';

// The vehicle pages' parts (migration 0097): the head with the studio stand-in, the specs, the cost of driving, the
// years, similar models, our inventory with live availability and the request link, the questions.

export type Inventory = { exact: CarRow[]; same_model: CarRow[]; similar: CarRow[]; real_exact: number; lastmod: string | null };

/** The studio stand-in image for a page (the sample cars' drawing, the model's name behind the car). */
export function standIn(o: { path: string; group: string; vclass: string | null; model: string; paint?: string }) {
  return `/sample-photos/studio/${shapeFor(o.group, o.vclass)}/${o.paint ?? paintFor(o.path)}/lead/${encodeURIComponent(studioName(o.model) || 'CAR')}.svg`;
}

export function VehicleHead({ trail, h1, lead, img, alt, facts, cta = ['#inventory', 'See cars to rent'], photo = null }: { trail: Trail; h1: string; lead: string; img: string; alt: string; facts: Array<[string, string]>; cta?: [string, string]; photo?: StockPhoto | null }) {
  return (
    <section className="page-head on-dark vp-head">
      <div className="wrap vp-head__grid">
        <div className="vp-head__text">
          <Crumbs trail={trail} />
          <h1 className="d1 vp-head__h1">{h1}</h1>
          <p className="lead muted">{lead}</p>
          {facts.length > 0 && <dl className="keyspecs vp-head__facts">{facts.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>}
          <p className="vp-head__cta"><a className="btn btn--primary btn--lg" href={cta[0]}>{cta[1]}</a></p>
        </div>
        {/* 0137: the licensed photo of the model's generation with its credit (a photo of another year says so); else the studio drawing */}
        {photo ? <StockFigure p={photo} alt={stockAlt(photo)} className="vp-head__media" main note={stockNote(photo)} />
          : <figure className="vp-head__media photo photo--32">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={img} alt={alt} width={1800} height={1200} decoding="async" fetchPriority="high" />
          <figcaption className="car-card__sample">Representative image</figcaption>
        </figure>}
      </div>
    </section>
  );
}

/** The specs of one or more powertrains: a column each (a table that scrolls on a phone when there are several). */
export function SpecsTable({ sp, seats, caption }: { sp: Spec[]; seats?: number | null; caption: string }) {
  if (!sp.length) return <p className="small muted">EPA has no fuel-use rating for this model year (heavier trucks and vans are not rated). The trims and our cars are below.</p>;
  const rows: Array<[string, (x: Spec) => string]> = [
    ['Engine', (x) => x.engine], ['Drive', (x) => x.drive ?? ''], ['Transmission', (x) => x.trans ?? ''], ['Fuel', (x) => x.fuelWord],
    ...(seats ? [['Seats', () => String(seats)] as [string, (x: Spec) => string]] : []),
    ['City', (x) => (x.kwh100 ? '' : x.l100_city ? `${x.l100_city.toFixed(1)} L/100 km` : '')],
    ['Highway', (x) => (x.kwh100 ? '' : x.l100_hwy ? `${x.l100_hwy.toFixed(1)} L/100 km` : '')],
    ['Combined', (x) => ratingText(x)],
    ['Electric range', (x) => (x.ev_range_km ? `${x.ev_range_km} km` : '')],
    ['CO₂', (x) => (x.co2_g_km !== null ? `${x.co2_g_km} g/km` : '')],
    ['Cost to drive 100 km', (x) => dollars(x.cost100)]
  ];
  const shown = rows.filter(([, f]) => sp.some((x) => f(x)));
  if (sp.length === 1) {
    const x = sp[0]!;
    return <table className="spec" data-testid="vp-specs"><caption className="vh">{caption}</caption><tbody>{shown.map(([k, f]) => <tr key={k}><th scope="row">{k}</th><td>{f(x) || 'Not rated'}</td></tr>)}</tbody></table>;
  }
  return (
    <div className="table-scroll" tabIndex={0} role="region" aria-label={caption}>
      <table className="data vp-specs" data-testid="vp-specs"><caption className="vh">{caption}</caption>
        <thead><tr><th scope="col">Spec</th>{sp.map((x, i) => <th key={x.key} scope="col">Powertrain {i + 1}</th>)}</tr></thead>
        <tbody>{shown.map(([k, f]) => <tr key={k}><th scope="row">{k}</th>{sp.map((x) => <td key={x.key}>{f(x) || 'Not rated'}</td>)}</tr>)}</tbody>
      </table>
    </div>
  );
}

export function CostBlock({ sp, s, name }: { sp: Spec[]; s: { gas_cents: number; premium_extra_cents: number; elec_cents: number }; name: string }) {
  const rated = sp.filter((x) => x.cost100 !== null);
  if (!rated.length) return null;
  return (
    <section className="vp-sec" aria-labelledby="h-cost" data-testid="vp-cost">
      <h2 className="d3" id="h-cost">Cost to drive the {name}</h2>
      <p className="small muted measure">From the EPA combined rating at {list([...new Set(rated.map((x) => priceBasis(x, s)))])} (our current Toronto price setting). You return the car with the same {rated.every((x) => x.fuel === 'electric') ? 'charge' : 'fuel'} it had at pickup, so this is what you pay for the driving.</p>
      <div className="table-scroll" tabIndex={0} role="region" aria-label={`Cost to drive the ${name}`}>
        <table className="data"><thead><tr><th scope="col">Powertrain</th><th scope="col">Uses</th>{tripCosts(rated[0]!).map(([k]) => <th key={k} scope="col" className="r">{k}</th>)}</tr></thead>
          <tbody>{rated.map((x) => <tr key={x.key}><th scope="row">{[x.engine, x.drive].filter(Boolean).join(', ')}</th><td>{ratingText(x)}</td>{tripCosts(x).map(([k, v]) => <td key={k} className="r">{v}</td>)}</tr>)}</tbody>
        </table>
      </div>
    </section>
  );
}

/** A model's years: fuel use, powertrains and trims, each linking to its year page. */
export function YearsTable({ years, current, caption }: { years: YearRow[]; current?: number; caption: string }) {
  if (!years.length) return null;
  const use = (y: YearRow) => [y.l100_min !== null ? (y.l100_min === y.l100_max ? `${Number(y.l100_min).toFixed(1)} L/100 km` : `${Number(y.l100_min).toFixed(1)} to ${Number(y.l100_max).toFixed(1)} L/100 km`) : '',
    y.kwh100_min !== null ? `from ${Number(y.kwh100_min).toFixed(1)} kWh/100 km` : ''].filter(Boolean).join(', ') || 'Not rated';
  return (
    <div className="table-scroll" tabIndex={0} role="region" aria-label={caption}>
      <table className="data" data-testid="vp-years"><caption className="vh">{caption}</caption>
        <thead><tr><th scope="col">Year</th><th scope="col">Combined use</th><th scope="col">Powertrains</th><th scope="col">Canadian trims</th></tr></thead>
        <tbody>{years.map((y) => (
          <tr key={y.year} aria-current={y.year === current ? 'page' : undefined}>
            <th scope="row">{y.year === current ? <b>{y.year}</b> : <Link prefetch={false} className="link" href={y.path}>{y.year}</Link>}</th>
            <td>{use(y)}</td><td>{y.powertrains || ''}{y.fuels.length ? ` (${y.fuels.map((f) => fuelWord(f).toLowerCase()).join(', ')})` : ''}</td>
            <td>{y.trims.length ? y.trims.map((t) => t.name).join(', ') : ''}</td>
          </tr>))}</tbody>
      </table>
    </div>
  );
}

export type SimilarModel = { make: string; model: string; year: number; path: string; l100_min: number | null; kwh100_min: number | null; ev_range_max: number | null; fuels: string[] };
export function SimilarModels({ items, title }: { items: SimilarModel[]; title: string }) {
  if (!items.length) return null;
  return (
    <section className="vp-sec" aria-labelledby="h-simmod">
      <h2 className="d3" id="h-simmod">{title}</h2>
      <ul className="hub-grid">{items.map((m) => (
        <li key={m.path}><Link prefetch={false} className="hub-card" href={m.path}><h3>{m.year} {m.make} {m.model}</h3>
          <p>{m.kwh100_min !== null ? `${Number(m.kwh100_min).toFixed(1)} kWh/100 km${m.ev_range_max ? `, up to ${m.ev_range_max} km range` : ''}` : m.l100_min !== null ? `From ${Number(m.l100_min).toFixed(1)} L/100 km combined` : 'Not rated by EPA'}</p></Link></li>))}</ul>
    </section>
  );
}

/** The request link of the existing enquiry flow (the contact form with the car named, a lead in Admin > Leads). */
export const requestHref = (name: string) => `/contact?topic=car&car=${encodeURIComponent(name)}`;

function Cards({ cars, labels }: { cars: CarRow[]; labels: Record<string, string> }) {
  return <ul className="fleet-grid fleet-grid--3">{cars.map((c) => <li key={c.slug}><CarCard c={c} labels={labels} /><Availability id={c.vehicle_id} /></li>)}</ul>;
}

/** Our cars: the exact match first, then the same model in other years, then similar cars, never an empty block. */
export function InventoryBlock({ inv, labels, name, exactLabel, sameLabel }: { inv: Inventory; labels: Record<string, string>; name: string; exactLabel: string; sameLabel: string }) {
  return (
    <section className="section on-grey vp-inv" id="inventory" aria-labelledby="h-inv" data-testid="vp-inventory">
      <div className="wrap">
        <h2 className="d2" id="h-inv">{inv.exact.length ? exactLabel : `Rent a ${name} in Toronto`}</h2>
        {inv.exact.length > 0 ? <Cards cars={inv.exact} labels={labels} />
          : <p className="lead muted" data-testid="vp-none">We have no {name} on the site right now. Request one and we look for it for your dates, or take a similar car that is available now.</p>}
        {inv.same_model.length > 0 && <><h3 className="d3 vp-inv__h">{sameLabel}</h3><Cards cars={inv.same_model} labels={labels} /></>}
        {inv.similar.length > 0 && <><h3 className="d3 vp-inv__h">Similar cars available now</h3><Cards cars={inv.similar} labels={labels} /></>}
        <div className="vp-request" data-testid="vp-request">
          <div><h3 className="d4">Want this exact car?</h3><p className="small muted">Tell us your dates and we look for a {name} for you. Nothing is booked or charged.</p></div>
          <Link prefetch={false} className="btn btn--primary" href={requestHref(name)} rel="nofollow">Request it</Link>
        </div>
      </div>
    </section>
  );
}

export function Questions({ items, title }: { items: Array<{ question: string; answer: string }>; title: string }) {
  return (
    <section className="vp-sec" aria-labelledby="h-q">
      <h2 className="d3" id="h-q">{title}</h2>
      <Faq items={items} />
    </section>
  );
}

/** JSON-LD Product for the page's model: offers only when real cars of ours match exactly (never for samples). */
export function productLd(o: { name: string; make: string; model: string; year?: number; trim?: string; path: string; image: string; description: string; inv: Inventory; fuel?: string; body?: string | null; extra?: Record<string, unknown>; offers?: boolean; photo?: StockPhoto | null }) {
  const url = siteUrl() + o.path;
  const real = o.inv.exact.filter((c) => !c.is_sample);
  const prices = real.map((c) => c.daily_rate_cents);
  return {
    '@type': ['Product', 'Car'], '@id': `${url}#vehicle`, name: o.name, url, image: o.photo ? photoLd(o.photo, stockAlt(o.photo)) : siteUrl() + o.image, description: o.description,
    brand: { '@type': 'Brand', name: o.make }, manufacturer: { '@type': 'Organization', name: o.make }, model: o.model,
    ...(o.year ? { vehicleModelDate: String(o.year) } : {}), ...(o.trim ? { vehicleConfiguration: o.trim } : {}), ...(o.fuel ? { fuelType: o.fuel } : {}), ...(o.body ? { bodyType: o.body } : {}),
    ...(o.extra ?? {}),
    ...(real.length && o.offers !== false ? { offers: { '@type': 'AggregateOffer', priceCurrency: 'CAD', lowPrice: (Math.min(...prices) / 100).toFixed(2), highPrice: (Math.max(...prices) / 100).toFixed(2),
      offerCount: real.length, businessFunction: 'http://purl.org/goodrelations/v1#LeaseOut', availability: 'https://schema.org/InStock',
      seller: { '@id': `${siteUrl()}/#business` }, url } } : {})
  };
}

export const fromPrice = (inv: Inventory) => { const p = inv.exact.filter((c) => !c.is_sample).map((c) => c.daily_rate_cents); return p.length ? money(Math.min(...p)) : null; };
