import Link from 'next/link';
import type { Metadata } from 'next';
import { JsonLd } from '@/components/JsonLd';
import { studioPaint } from '@/features/car/studio';
import { breadcrumbLd, faqLd, type Trail } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { fill, getClasses, getTokens } from '@/lib/site';
import type { CarRow } from '@/lib/types';
import { type Dim, dimRows, dimsFor, dollars, fit, fuelWord, list, priceBasis, ptName, ratingRange, ratingText, rentalFaq, specs, statRows, type Spec,
  tierDescriptionOptions, tierTitleOptions, trimDiffs } from './content';
import { type TrimPage, vehicleMeta } from './data';
import { CostBlock, type Inventory, InventoryBlock, productLd, Questions, SimilarModels, SpecsTable, standIn, VehicleHead } from './parts';

// The figures people look up, on every trim page and its city, colour and /buy twins (migration 0092), and the city and
// colour pages themselves. Only sourced figures: EPA and vPIC's Canadian specifications; no source, no row.

export type Colour = { slug: string; name: string; hex: string };
/** A place (0092): a city, town, neighbourhood or airport (local: a distance and a delivery price), or a region, province
 *  or country (the places within it instead). */
export type City = { slug: string; name: string; kind: string; parent: string | null; facts: Record<string, unknown>; landing: string | null; km: number | null;
  delivery: { fee_cents: number | null; km: number | null; airport_code?: string | null; airport_name?: string | null; per_km_cents?: number | null; min_cents?: number | null } | null;
  nearby: Array<{ slug: string; name: string; km: number | null }>; within: Array<{ slug: string; name: string }> };
export type Term = { slug: string; name: string; kind: 'rental' | 'sale' | 'detailing' | 'bodyshop' };
export type Tiers = { settings: Record<string, unknown>; places: Array<{ slug: string; name: string; kind: string }>; place_count: number; colours: Colour[]; terms: Term[] };
export type TierPage = Omit<TrimPage, 'level'> & { level: 'city' | 'colour' | 'city_colour'; trim_path: string; city: City | null; colour: Colour | null; tiers: Tiers; dims?: Dim[] };

const labelsOf = async () => Object.fromEntries((await getClasses()).map((c) => [c.code, c.label]));
const km1 = (n: number | null | undefined) => (n === null || n === undefined ? null : Number(n).toLocaleString('en-CA', { maximumFractionDigits: 1 }));
const arr = (v: unknown) => (Array.isArray(v) ? v.map(String).filter(Boolean) : []);
const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : '');

/** Every sourced figure of the powertrains and the bodies, with where each comes from. */
export function StatsBlock({ sp, dims, model, trim, name, s, seats }: { sp: Spec[]; dims?: Dim[]; model: string; trim?: string; name: string; seats?: number | null;
  s: { gas_cents: number; premium_extra_cents: number; elec_cents: number } }) {
  const rows = statRows(sp, s);
  const bodies = dimsFor(dims, model, trim);
  const drows = dimRows(bodies);
  if (!rows.length && !drows.length && !seats) return null;
  const many = sp.length > 1;
  return (
    <section className="vp-sec" aria-labelledby="h-figures" data-testid="vp-figures">
      <h2 className="d3" id="h-figures">{name}: every figure</h2>
      {rows.length > 0 && <div className="table-scroll" tabIndex={0} role="region" aria-label={`${name} figures`}>
        <table className="data vp-specs"><caption className="vh">{name} figures by powertrain</caption>
          {many && <thead><tr><th scope="col">Figure</th>{sp.map((x, i) => <th key={x.key} scope="col">Powertrain {i + 1}</th>)}</tr></thead>}
          <tbody>{rows.map((r) => <tr key={r.label}><th scope="row">{r.label}{r.note ? <span className="xs muted"> ({r.note})</span> : null}</th>{r.values.map((v, i) => <td key={i}>{v || ''}</td>)}</tr>)}
            {seats ? <tr><th scope="row">Seats<span className="xs muted"> (our car of this model)</span></th>{sp.map((x) => <td key={x.key}>{seats}</td>)}</tr> : null}</tbody>
        </table></div>}
      {drows.length > 0 && <div className="table-scroll" tabIndex={0} role="region" aria-label={`${name} dimensions`}>
        <table className="data" data-testid="vp-dims"><caption className="vh">{name} dimensions and weight</caption>
          <thead><tr><th scope="col">Dimension</th>{bodies.map((b) => <th key={b.body} scope="col">{b.body.toLowerCase().replace(/(^|\s)\S/g, (c) => c.toUpperCase())}</th>)}</tr></thead>
          <tbody>{drows.map((r) => <tr key={r.label}><th scope="row">{r.label}</th>{r.values.map((v, i) => <td key={i}>{v}</td>)}</tr>)}</tbody>
        </table></div>}
      <p className="xs muted" data-testid="vp-sources">Sources: fuel use, MPG, CO2, electric range, battery, charge time, luggage volume and the annual fuel cost are the US EPA&apos;s (fueleconomy.gov){drows.length ? '; dimensions and curb weight are NHTSA vPIC Canadian vehicle specifications, by body' : ''}. Imperial MPG, litres, inches and pounds are converted from those figures. Figures no free source publishes for this car (power, torque, acceleration, top speed, fuel tank, towing) are left out.</p>
    </section>
  );
}

/** The schema.org Vehicle figures of a page (only those a source gives). */
export function vehicleProps(sp: Spec[], dims: Dim[], seats?: number | null, colour?: string | null): Record<string, unknown> {
  const q = (value: number, unitCode: string, unitText?: string) => ({ '@type': 'QuantitativeValue', value, unitCode, ...(unitText ? { unitText } : {}) });
  const x = sp[0]; const d = dims[0];
  const out: Record<string, unknown> = {};
  if (x?.l100_comb) out.fuelConsumption = q(x.l100_comb, 'LTR', 'L/100 km');
  else if (x?.kwh100) out.fuelConsumption = q(x.kwh100, 'KWH', 'kWh/100 km');
  if (x?.mpg_comb && x.fuel !== 'electric') out.fuelEfficiency = q(x.mpg_comb, 'MPG', 'MPG (US)');
  if (x && (x.displ || x.fuel)) out.vehicleEngine = { '@type': 'EngineSpecification', ...(x.displ ? { engineDisplacement: q(x.displ, 'LTR') } : {}), fuelType: fuelWord(x.fuel), name: x.engine };
  if (x?.trans) out.vehicleTransmission = x.trans;
  if (x?.drive) out.driveWheelConfiguration = x.drive;
  if (x?.luggage_cuft) out.cargoVolume = q(Math.round(x.luggage_cuft * 28.3168), 'LTR');
  if (x?.co2_g_km !== null && x?.co2_g_km !== undefined) out.emissionsCO2 = x.co2_g_km;
  if (d?.curb_kg) out.weight = q(d.curb_kg, 'KGM');
  if (d?.length_cm) out.depth = q(d.length_cm, 'CMT');
  if (d?.width_cm) out.width = q(d.width_cm, 'CMT');
  if (d?.height_cm) out.height = q(d.height_cm, 'CMT');
  if (d?.wheelbase_cm) out.wheelbase = q(d.wheelbase_cm, 'CMT');
  if (seats) out.seatingCapacity = seats;
  if (colour) out.color = colour;
  return out;
}

/** Our cars of the colour first in each group of the inventory. */
export function colourFirst(inv: Inventory, colour: string | null): Inventory {
  if (!colour) return inv;
  const k = (c: CarRow) => (studioPaint(c.colour) === colour && c.colour ? 0 : 1);
  const s = (xs: CarRow[]) => [...xs].sort((a, b) => k(a) - k(b));
  return { ...inv, exact: s(inv.exact), same_model: s(inv.same_model), similar: s(inv.similar) };
}

/** The city and colour pages a trim page (or one of its twins) links to. */
export function TierLinks({ base, tiers, city, colour, name, prefix = '' }: { base: string; tiers: Tiers; city?: string | null; colour?: string | null; name: string; prefix?: string }) {
  if (!tiers.places.length && !tiers.colours.length) return null;
  return (
    <section className="vp-sec" aria-labelledby="h-tiers" data-testid="vp-tiers">
      <h2 className="d3" id="h-tiers">{prefix}The {name} {city ? 'nearby and ' : ''}by place and colour</h2>
      {tiers.places.length > 0 && <><h3 className="d4">{colour ? `In ${tiers.colours.find((c) => c.slug === colour)?.name.toLowerCase()}, by place` : 'By place'}</h3>
        <ul className="chips">{tiers.places.map((c) => <li key={c.slug}>{c.slug === city ? <span className="chip" aria-current="page">{c.name}</span>
          : <Link prefetch={false} className="chip" href={`${base}/${c.slug}${colour ? `/${colour}` : ''}`}>{c.name}</Link>}</li>)}</ul></>}
      {tiers.colours.length > 0 && <><h3 className="d4">{city ? `In ${tiers.places.find((c) => c.slug === city)?.name ?? 'this place'}, by colour` : 'By colour'}</h3>
        <ul className="chips">{tiers.colours.map((c) => <li key={c.slug}>{c.slug === colour ? <span className="chip" aria-current="page">{c.name}</span>
          : <Link prefetch={false} className="chip" href={city ? `${base}/${city}/${c.slug}` : `${base}/colour/${c.slug}`}><span className="vp-swatch" style={{ background: c.hex }} aria-hidden="true" />{c.name}</Link>}</li>)}</ul></>}
      {tiers.terms.length > 0 && <><h3 className="d4">For sale, detailing, body shop and other searches</h3>
        <ul className="chips"><li><Link prefetch={false} className="chip" href={`/buy${base.slice(5)}${city ? `/${city}` : ''}${colour ? (city ? `/${colour}` : `/colour/${colour}`) : ''}`}>For sale</Link></li>
          {tiers.terms.map((x) => <li key={x.slug}><Link prefetch={false} className="chip" href={`/t/${x.slug}${base.slice(5)}${city ? `/${city}` : ''}${colour ? (city ? `/${colour}` : `/colour/${colour}`) : ''}`}>{x.name}</Link></li>)}</ul></>}
    </section>
  );
}

/** What a delivery to the place costs, in words, from the stored values only. */
export function deliveryText(c: City): string {
  const d = c.delivery;
  if (!d) return `We deliver anywhere in ${c.name}: the price in your offer counts the distance from our location.`;
  if (d.fee_cents !== null && d.fee_cents !== undefined) return `Delivery ${d.airport_name ? `to ${d.airport_name}` : `to ${c.name}`} starts at ${money(d.fee_cents)}${d.km ? `, for ${km1(d.km)} km from our location (straight line)` : ''}.`;
  if (d.per_km_cents) return `Delivery to ${c.name} is priced by distance, ${dollars(d.per_km_cents)} a km${d.min_cents ? ` with a minimum of ${money(d.min_cents)}` : ''}, shown in your offer.`;
  return `Delivery to ${c.name} is priced in your offer by the distance from our location.`;
}

/** The city's own block: distance, delivery, the landing page's local notes, nearby cities. */
export function CityBlock({ c, name, linkBase, colour }: { c: City; name: string; linkBase: string; colour?: string | null }) {
  const f = c.facts;
  const notes: Array<[string, string]> = [
    ['Areas', list(arr(f.areas))], ['Airport', str(f.airport)], ['Terminals', list(arr(f.terminals))], ['Getting there', list([...arr(f.links), ...arr(f.access)])],
    ['Transit', list(arr(f.transit))], ['Highways', list(arr(f.highways))], ['Toll road', str(f.toll_road)], ['Parking', str(f.parking)], ['Street', str(f.street)],
    ['Landmarks', list(arr(f.landmarks))]].filter(([, v]) => v) as Array<[string, string]>;
  return (
    <section className="vp-sec" aria-labelledby="h-city" data-testid="vp-city">
      <h2 className="d3" id="h-city">The {name} in {c.name}</h2>
      <p className="measure">{c.parent ? `${c.name}, ${c.parent}. ` : ''}{deliveryText(c)}{c.km ? ` ${c.name} is ${km1(c.km)} km from our location in a straight line.` : ''} Collecting the car yourself is free.</p>
      {notes.length > 0 && <dl className="kv vp-citynotes">{notes.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>}
      {c.landing && <p className="small"><Link prefetch={false} className="link" href={c.landing}>Car rental in {c.name}</Link></p>}
      {c.within.length > 0 && <><h3 className="d4">The {name} in places of {c.name}</h3>
        <ul className="chips">{c.within.map((n) => <li key={n.slug}><Link prefetch={false} className="chip" href={`${linkBase}/${n.slug}${colour ? `/${colour}` : ''}`}>{n.name}</Link></li>)}</ul></>}
      {c.nearby.length > 0 && <><h3 className="d4">The {name} near {c.name}</h3>
        <ul className="chips">{c.nearby.map((n) => <li key={n.slug}><Link prefetch={false} className="chip" href={`${linkBase}/${n.slug}${colour ? `/${colour}` : ''}`}>{n.name}{n.km ? ` (${km1(n.km)} km)` : ''}</Link></li>)}</ul></>}
    </section>
  );
}

/** The city's questions, answered from its stored values. */
export function cityFaq(c: City, name: string): Array<{ question: string; answer: string }> {
  const q = [{ question: `Can the ${name} be delivered in ${c.name}?`, answer: `${deliveryText(c)} You can also collect it from us for free.` }];
  if (c.km) q.push({ question: `How far is ${c.name} from {{brand}}?`, answer: `${km1(c.km)} km from our location in a straight line; the delivery price counts the distance.` });
  if (c.delivery?.airport_name) q.push({ question: `Can I get the car at ${c.delivery.airport_name}?`, answer: `Yes. We meet you at ${c.delivery.airport_name}${arr(c.facts.terminals).length ? ` (${list(arr(c.facts.terminals))})` : ''}; the airport delivery fee is in your offer.` });
  if (c.nearby.length) q.push({ question: `Do you also cover places near ${c.name}?`, answer: `Yes: ${list(c.nearby.map((n) => n.name))}, among others. Every area we deliver to has its own page.` });
  return q;
}

// ---------------------------------------------------------------- the city, city and colour, and colour pages
const tierName = (p: TierPage) => `${p.year} ${p.make.name} ${p.model.name} ${p.trim.name}`;

export async function tierMeta(p: TierPage): Promise<Metadata> {
  const t = await getTokens();
  const sp = specs(p.variants, p.settings, p.trim.variant_ids);
  const o = { make: p.make.name, model: p.model.name, year: p.year, trim: p.trim.name, city: p.city?.name, colour: p.colour?.name };
  return vehicleMeta({ title: fit(tierTitleOptions({ ...o, home: t.city }), (x) => fill(x, t), 70), path: p.path, indexable: p.indexable, canonical: p.canonical,
    description: fit(tierDescriptionOptions({ ...o, use: ratingRange(sp), km: p.city?.km ?? null, fee: p.city?.delivery?.fee_cents ? money(p.city.delivery.fee_cents) : null, cars: p.inventory.exact.length }), (x) => fill(x, t), 170, 70),
    image: standIn({ path: p.trim_path, group: p.body_group, vclass: p.vclass, model: p.model.name, paint: p.colour?.slug }),
    imageAlt: `${p.colour ? `${p.colour.name} ` : ''}${tierName(p)} studio image` });
}

export async function TierView({ p }: { p: TierPage }) {
  const [t, labels] = await Promise.all([getTokens(), labelsOf()]);
  const F = (x: string) => fill(x, t);
  const name = tierName(p);
  const colourWord = p.colour ? p.colour.name.toLowerCase() : '';
  const modelPath = `/cars/${p.make.slug}/${p.model.slug}`;
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [p.make.name, `/cars/${p.make.slug}`], [p.model.name, modelPath], [String(p.year), `${modelPath}/${p.year}`], [p.trim.name, p.trim_path],
    ...(p.city ? [[p.city.name, p.colour ? `${p.trim_path}/${p.city.slug}` : undefined] as [string, string?]] : []), ...(p.colour ? [[p.colour.name] as [string]] : [])] as Trail;
  const img = standIn({ path: p.trim_path, group: p.body_group, vclass: p.vclass, model: p.model.name, paint: p.colour?.slug });
  const sp = specs(p.variants, p.settings, p.trim.variant_ids);
  const diffs = trimDiffs(p.trim, p.siblings, p.variants, p.settings);
  const inv = colourFirst(p.inventory, p.colour?.slug ?? null);
  const inColour = p.colour ? inv.exact.concat(inv.same_model, inv.similar).filter((c) => studioPaint(c.colour) === p.colour!.slug && c.colour).length : 0;
  const seats = inv.exact.find((c) => c.seats)?.seats ?? null;
  const cheapest = sp.filter((x) => x.cost100 !== null)[0];
  const where = p.city ? p.city.name : t.city;
  const h1 = p.city ? `Rent ${p.colour ? `${/^[aeiou]/i.test(colourWord) ? 'an' : 'a'} ${colourWord} ` : 'a '}${name} in ${p.city.name}` : `The ${name} in ${colourWord}`;
  const h1u = p.city && !p.colour && p.city.name === t.city ? `${h1}: delivery and pickup` : h1;
  const lead = [p.city ? deliveryText(p.city) : `Our ${colourWord} cars come first below${inColour ? ` (${inColour} now)` : ''}; the studio image shows the ${p.model.name} in ${colourWord}.`,
    sp.length ? `Rated ${ratingRange(sp)} combined${cheapest ? `, about ${dollars(cheapest.cost100)} of ${cheapest.fuel === 'electric' ? 'electricity' : 'fuel'} per 100 km` : ''}.` : ''].filter(Boolean).join(' ');
  const faq = [...(p.city ? cityFaq(p.city, name) : []),
    ...(p.colour ? [{ question: `Can I choose a ${colourWord} ${name}?`, answer: inColour ? `Yes: ${inColour === 1 ? 'one of our cars below is' : `${inColour} of our cars below are`} ${colourWord}. Ask for the colour when you request it.` : `We have no ${colourWord} car of this kind on the site now. Request the ${name} in ${colourWord} and we look for one for your dates; a colour can never be promised before we confirm.` }] : []),
    ...rentalFaq({ name, cars: inv.exact.length, similar: inv.similar.length + inv.same_model.length, ev: cheapest?.fuel === 'electric', cost100: cheapest ? dollars(cheapest.cost100) : null,
      cheapestUse: cheapest ? `${ratingText(cheapest)} (${ptName(cheapest)})` : undefined, basis: cheapest ? priceBasis(cheapest, p.settings) : undefined }).filter((q) => !/delivered\?$/.test(q.question) || !p.city)];
  const questions = faq.map((q) => ({ question: F(q.question).replace(/in Toronto\?$/, `in ${where}?`), answer: F(q.answer) }));
  return (
    <div className="p-vehicle" data-page={`vehicle-${p.level.replace('_', '-')}`}>
      <JsonLd graph={[breadcrumbLd(trail, p.path), productLd({ name: p.colour ? `${p.colour.name} ${name}` : name, make: p.make.name, model: p.model.name, year: p.year, trim: p.trim.name, path: p.path, image: img, description: lead,
        inv, fuel: sp[0] ? fuelWord(sp[0].fuel) : undefined, body: p.vclass, extra: vehicleProps(sp, dimsFor(p.dims, p.model.name, p.trim.name), seats, p.colour?.name ?? null) }), faqLd(questions)]} />
      <VehicleHead trail={trail} h1={h1u} lead={lead} img={img} alt={`${p.colour ? `${p.colour.name} ` : ''}${name} in the studio, a representative image`}
        facts={[['Engine', sp.length === 1 ? sp[0]!.engine : sp.length ? `${sp.length} choices` : ''], ['Combined', sp.length ? ratingRange(sp).split(', or')[0]! : ''],
          ...(p.city ? [['Delivery', p.city.delivery?.fee_cents ? `from ${money(p.city.delivery.fee_cents)}` : 'in your offer'] as [string, string]] : []),
          ...(p.colour ? [['Colour', p.colour.name] as [string, string]] : []), ['Our cars', String(inv.exact.length)]].filter(([, v]) => v) as Array<[string, string]>} />
      <div className="wrap vp-body">
        {p.city && <CityBlock c={p.city} name={name} linkBase={p.trim_path} colour={p.colour?.slug} />}
        <section className="vp-sec" aria-labelledby="h-specs">
          <h2 className="d3" id="h-specs">{name} specs</h2>
          <SpecsTable sp={sp} seats={seats} caption={`${name} powertrains`} />
        </section>
        <StatsBlock sp={sp} dims={p.dims} model={p.model.name} trim={p.trim.name} name={name} s={p.settings} seats={seats} />
        <CostBlock sp={sp} s={p.settings} name={name} />
        <section className="vp-sec" aria-labelledby="h-diff">
          <h2 className="d3" id="h-diff">The {p.trim.name} and the other {p.year} trims</h2>
          <ul className="featlist">{diffs.map((d) => <li key={d}>{d}</li>)}</ul>
          <ul className="chips">{p.siblings.filter((x) => x.slug !== p.trim.slug).map((x) => <li key={x.slug}><Link prefetch={false} className="chip" href={`${x.path}${p.city ? `/${p.city.slug}` : ''}${p.colour ? (p.city ? `/${p.colour.slug}` : `/colour/${p.colour.slug}`) : ''}`}>{x.name}</Link></li>)}</ul>
          <p className="small"><Link prefetch={false} className="link" href={p.trim_path}>Everything about the {name}</Link></p>
        </section>
        <TierLinks base={p.trim_path} tiers={p.tiers} city={p.city?.slug} colour={p.colour?.slug} name={name} />
        <SimilarModels items={p.similar_models} title={`Other ${p.year} ${(p.vclass ?? 'cars').toLowerCase()} like it`} />
      </div>
      <InventoryBlock inv={inv} labels={labels} name={p.colour ? `${colourWord} ${name}` : name} exactLabel={`Our ${name} cars${p.colour ? `, ${colourWord} first` : ''}`} sameLabel={`Other ${p.make.name} ${p.model.name} cars we have`} />
      <div className="wrap vp-body"><Questions items={questions} title={`Renting the ${name}${p.city ? ` in ${p.city.name}` : ''}${p.colour ? ` in ${colourWord}` : ''}`} /></div>
    </div>
  );
}
