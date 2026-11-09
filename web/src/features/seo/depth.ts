// The depth sections of the programmatic pages (release 35, part M; docs/changes/2026-11-08-r35-seo-depth.md): cars
// and prices, local logistics, requirements, the car's figures, a comparison checklist, questions and related links,
// every sentence written from the page's own data (the database's facts, the sourced page data, the vetted city facts
// of local-data.ts) or a value computed from it (a distance, a drive time, a cost to drive 100 km). A fact that is not
// in the input is left out, with its sentence: there is no generic text. Pure and fast (no database, no model).
// Relative imports only (the unit test runs it in Node).
import { money } from '../../lib/format.ts';
import { driveMinutes } from '../places/copy.ts';
import { cityFacts, ETR407 } from './local-data.ts';

export interface DepthTable { head: string[]; rows: string[][] }
export interface DepthSection { id: 'cars' | 'logistics' | 'requirements' | 'car' | 'maintenance' | 'compare' | 'related'; heading: string; paras: string[]; table?: DepthTable; links?: Array<{ href: string; label: string }> }
export interface DepthText { sections: DepthSection[]; faq: Array<{ question: string; answer: string }>; attributions: string[]; words: number }

/** The site's facts every page shows (public.site_facts and the Program settings behind it). */
export interface DepthFacts {
  brand: string; minAge: number; youngBands: Array<{ from: number; to: number; feeCents: number | null }>; licenceClasses: string[]; otherLicenceReview: boolean;
  depositTiersCents: number[]; tollFeeCents: number | null; additionalDriverBps: number | null; deductibleCents: number | null; hstBps: number;
  maxDays: number; weekFrom: number; coverOptions: string[]; airports: string[];
  /** cents a litre of regular gas, extra for premium, cents a kWh (Program settings, the vehicle pages' prices) */
  fuel?: { gasCents: number; premiumExtraCents: number; kwhCents: number } | null;
  /** the fee schedule (fee types with a standard amount, before HST) */
  fees?: Array<{ label: string; unit: string; amountCents: number; capCents: number | null }>;
  /** booking notice and the cancellation tiers (Program settings) */
  noticeHours?: number | null; cancellation?: { graceHours: number; graceBps: number; earlyHours: number; earlyBps: number; lateHours: number; midBps: number } | null;
}
export interface DepthCar {
  name: string; path: string; dailyCents: number; weeklyCents: number; monthlyCents: number; depositCents: number; kmPerDay?: number | null;
  seats?: number | null; transmission?: string | null; fuel?: string | null; className?: string | null; isSample?: boolean;
}
export interface DepthPoi { kind: 'go_station' | 'rail_station' | 'subway_station' | 'bus_stop' | 'hotel'; agency: string | null; name: string; km: number; source: 'gtfs' | 'osm'; attribution: string }
export interface DepthPlace {
  name: string; label: string; kind: string; region: string | null; parentCity?: string | null;
  /** straight-line km from the office (null when the place has no coordinates) */
  km: number | null; originLabel: string; inReach: boolean; reachKm: number; deliveryFromCents: number | null;
  airport?: { name: string; iata: string | null; km: number } | null;
  nearby?: Array<{ name: string; path: string; km?: number | null }>;
}
/** A spec row of vehicle_specs: its value and its source. */
export interface DepthSpec { field: string; value: string; code?: string | null; trim?: string; source: string; source_url: string }
export interface DepthVehicle {
  name: string; specs: DepthSpec[];
  /** L/100 km combined from the car's own facts when vehicle_specs has none (the listing's consumption) */
  l100?: number | null; kwh100?: number | null; premium?: boolean;
  maintenance?: { per_year_cents: number; per_10k_km_cents: number; assumptions: string; source: string; source_url: string } | null;
}
export interface DepthInput {
  path: string; facts: DepthFacts;
  /** the page's own cars (sample cars are left out of prices); fallback: the nearest similar cars when the page has none */
  cars: DepthCar[]; fallbackCars?: DepthCar[];
  place?: DepthPlace | null; pois?: DepthPoi[]; vehicle?: DepthVehicle | null;
  /** a comparison page: the company the searcher compared (named only as that) and whether it is a versus page */
  compare?: { company: string; versus: boolean } | null;
  related?: { cars?: Array<{ href: string; label: string }>; places?: Array<{ href: string; label: string }>; guides?: Array<{ href: string; label: string }> };
  topic?: string;
  /** sections the page already has in its own form (the car page's requirements) */
  omit?: DepthSection['id'][];
}

const T = (s: string) => s.replace(/\s+/g, ' ').trim();
const list = (xs: string[]) => (xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`);
const km1 = (n: number) => (n < 10 ? String(Math.round(n * 10) / 10) : String(Math.round(n)));
const pctOf = (bps: number) => `${+(bps / 100).toFixed(2)}%`;
const words = (s: string) => (s.match(/[\p{L}\p{N}$][\p{L}\p{N}$.,'%/-]*/gu) ?? []).length;
const POI_LABEL: Record<DepthPoi['kind'], string> = { go_station: 'GO stations', rail_station: 'Train stations', subway_station: 'Subway and LRT stations', bus_stop: 'Bus stops', hotel: 'Hotels' };

/** The specs by field (the first value of a field; several values of a list field). */
function specMap(specs: DepthSpec[]) {
  const one = new Map<string, DepthSpec>();
  const many = new Map<string, DepthSpec[]>();
  for (const s of specs) { if (!one.has(s.field)) one.set(s.field, s); many.set(s.field, [...(many.get(s.field) ?? []), s]); }
  return { one: (f: string) => one.get(f), many: (f: string) => many.get(f) ?? [] };
}

/** The cost to drive 100 km: litres (or kWh) a 100 km times the price set in Program settings. */
export function costPer100(v: { l100?: number | null; kwh100?: number | null; premium?: boolean }, fuel: DepthFacts['fuel']): { cents: number; basis: string } | null {
  if (!fuel) return null;
  if (v.kwh100 && v.kwh100 > 0) return { cents: Math.round(v.kwh100 * fuel.kwhCents), basis: `${v.kwh100} kWh per 100 km at ${money(fuel.kwhCents, { cents: true })} a kWh` };
  if (v.l100 && v.l100 > 0) { const c = fuel.gasCents + (v.premium ? fuel.premiumExtraCents : 0); return { cents: Math.round(v.l100 * c), basis: `${v.l100} L/100 km at ${money(c, { cents: true })} a litre of ${v.premium ? 'premium' : 'regular'} gas` }; }
  return null;
}
/** "7.8 L/100 km" (or "8.1 L/100km combined") from a listing's consumption text; null when it gives no figure. */
export function parseL100(text: string | null | undefined): number | null {
  const m = /(\d{1,2}(?:\.\d)?)\s*L\s*\/\s*100\s*km/i.exec(text ?? '');
  return m ? Number(m[1]) : null;
}

function carLine(c: DepthCar): string {
  const bits = [`${money(c.dailyCents)} a day`, `${money(c.weeklyCents)} a week`, `${money(c.monthlyCents)} for 30 days`, `a ${money(c.depositCents)} deposit`];
  if (c.kmPerDay) bits.push(`${c.kmPerDay} km a day included`);
  const FUEL: Record<string, string> = { gasoline: 'gas', diesel: 'diesel', hybrid: 'hybrid', plug_in_hybrid: 'plug-in hybrid', electric: 'electric' };
  const spec = [c.className ? c.className.replace(/_/g, ' ') : '', c.seats ? `${c.seats} seats` : '', c.transmission ? c.transmission.toLowerCase() : '', c.fuel && FUEL[c.fuel] ? FUEL[c.fuel]! : ''].filter(Boolean).join(', ');
  return T(`${c.name}: ${list(bits)}${spec ? ` (${spec})` : ''}.`);
}

/** The depth text of one page. */
export function buildDepth(x: DepthInput): DepthText {
  const f = x.facts;
  const p = x.place ?? null;
  const sections: DepthSection[] = [];
  const faq: DepthText['faq'] = [];
  const attributions: string[] = [];
  const real = x.cars.filter((c) => !c.isSample && c.dailyCents > 0);
  const where = p?.name ?? '';

  // ---------------------------------------------------------------- cars and prices
  {
    const paras: string[] = [];
    let table: DepthTable | undefined;
    const shown = real.length ? real : (x.fallbackCars ?? []).filter((c) => !c.isSample && c.dailyCents > 0).slice(0, 6);
    if (shown.length) {
      const sorted = [...shown].sort((a, b) => a.dailyCents - b.dailyCents);
      const lo = sorted[0]!, hi = sorted[sorted.length - 1]!;
      const weekLo = Math.min(...shown.map((c) => c.weeklyCents)), monthLo = Math.min(...shown.map((c) => c.monthlyCents));
      const depLo = Math.min(...shown.map((c) => c.depositCents)), depHi = Math.max(...shown.map((c) => c.depositCents));
      if (real.length) paras.push(T(`${real.length} ${real.length === 1 ? 'car matches' : 'cars match'} this page on ${f.brand} right now. Daily rates run from ${money(lo.dailyCents)} (${lo.name}) to ${money(hi.dailyCents)} (${hi.name}); the lowest weekly rate is ${money(weekLo)} and the lowest 30-day rate ${money(monthLo)}. ${depLo === depHi ? `The deposit is ${money(depLo)}` : `Deposits run from ${money(depLo)} to ${money(depHi)}`}, held on your card before pickup. Prices are before ${pctOf(f.hstBps)} HST.`));
      else paras.push(T(`No car matches this page exactly right now. The nearest similar cars on ${f.brand} start at ${money(lo.dailyCents)} a day (${lo.name}), ${money(weekLo)} a week and ${money(monthLo)} for 30 days${p && p.km !== null ? `, and any of them can be brought to ${where}, about ${driveMinutes(p.km)} minutes by road from ${p.originLabel}` : ''}.`));
      if (f.weekFrom) paras.push(T(`A trip of ${f.weekFrom} days or more is priced at the weekly rate, and one booking runs up to ${f.maxDays} days.`));
      for (const c of sorted.slice(0, 12)) paras.push(carLine(c));
      table = { head: ['Car', 'Day', 'Week', '30 days', 'Deposit'], rows: sorted.slice(0, 12).map((c) => [c.name, money(c.dailyCents), money(c.weeklyCents), money(c.monthlyCents), money(c.depositCents)]) };
      faq.push({ question: `How much does it cost to rent a car${where ? ` in ${where}` : ''} with ${f.brand}?`, answer: T(`From ${money(lo.dailyCents)} a day, ${money(weekLo)} a week or ${money(monthLo)} for 30 days before HST, on the cars listed today. The deposit is ${depLo === depHi ? money(depLo) : `${money(depLo)} to ${money(depHi)}`}, depending on the car.`) });
    }
    if (p && p.inReach && p.deliveryFromCents) {
      paras.push(T(`Delivery to ${where} starts at ${money(p.deliveryFromCents)} each way, worked out from the distance from ${p.originLabel}; collecting the car yourself costs nothing.`));
      faq.push({ question: `What does delivery to ${where} cost?`, answer: `From ${money(p.deliveryFromCents)} each way. The exact fee for your address is in your offer before you pay.` });
    } else if (p && !p.inReach && p.km !== null) {
      paras.push(T(`${where} is about ${km1(p.km)} km from ${p.originLabel}, beyond the ${p.reachKm} km ${f.brand} delivers to, so the cars are collected in Toronto.`));
    }
    if (paras.length) sections.push({ id: 'cars', heading: p ? `Cars and prices for ${where}` : 'Cars and prices', paras, table });
  }

  // ---------------------------------------------------------------- local logistics
  if (p && !['country', 'province', 'region', 'area'].includes(p.kind)) {
    const paras: string[] = [];
    if (p.km !== null) {
      const mins = driveMinutes(p.km);
      paras.push(T(`${where} is about ${km1(p.km)} km in a straight line from ${p.originLabel}, roughly ${mins} minutes by road (estimated from the distance).`));
      faq.push({ question: `How far is ${where} from ${f.brand}?`, answer: `About ${km1(p.km)} km in a straight line from ${p.originLabel}, roughly ${mins} minutes by car.` });
    }
    if (p.airport) {
      paras.push(T(`The nearest airport is ${p.airport.name}${p.airport.iata ? ` (${p.airport.iata})` : ''}, about ${km1(p.airport.km)} km away.${f.airports.length ? ` ${f.brand} delivers at ${list(f.airports)}.` : ''}`));
      faq.push({ question: `What is the nearest airport to ${where}?`, answer: `${p.airport.name}${p.airport.iata ? ` (${p.airport.iata})` : ''}, about ${km1(p.airport.km)} km away.` });
    }
    const pois = (x.pois ?? []).filter((q) => q.kind !== 'hotel');
    const go = pois.filter((q) => q.kind === 'go_station' || (q.kind === 'rail_station' && /^GO/i.test(q.agency ?? '')));
    if (go[0]) {
      paras.push(T(`The nearest GO station is ${go[0].name}, about ${km1(go[0].km)} km away${go.length > 1 ? `; ${list(go.slice(1, 3).map((g) => `${g.name} (${km1(g.km)} km)`))} are next` : ''}.`));
      faq.push({ question: `What is the nearest GO station to ${where}?`, answer: `${go[0].name}, about ${km1(go[0].km)} km away (GO Transit's published stop list).` });
    }
    const cf = cityFacts({ name: p.name, kind: p.kind, region: p.region }, p.parentCity);
    if (cf?.highways.length) {
      paras.push(T(`Highways through ${p.kind === 'neighbourhood' && p.parentCity ? p.parentCity : where}: ${list(cf.highways)}.`));
      if (cf.highways.some((h) => /407/.test(h))) {
        paras.push(T(`Highway 407 ETR has no toll booths: tolls are billed by plate after the trip. On a ${f.brand} rental the toll is yours${f.tollFeeCents ? `, plus ${money(f.tollFeeCents)} for each toll invoice we pass on` : ''}.`));
        faq.push({ question: `Can I drive a rental car on the 407 near ${where}?`, answer: T(`Yes. The 407 ETR bills tolls by plate; on a ${f.brand} rental the toll is yours${f.tollFeeCents ? `, plus ${money(f.tollFeeCents)} for each toll invoice` : ''}.`) });
        attributions.push(`407 ETR tolls: ${ETR407.source}`);
      }
      attributions.push(`Highways: ${cf.source}`);
    }
    if (cf?.parking) { paras.push(T(`Parking in ${p.parentCity && p.kind === 'neighbourhood' ? p.parentCity : where}: ${cf.parking.text}`)); attributions.push(`Parking rule: ${cf.parking.source}`); }
    let table: DepthTable | undefined;
    const lists = (x.pois ?? []).filter((q) => q.km <= 5);
    if (lists.length) {
      const kinds = [...new Set(lists.map((q) => q.kind))];
      for (const k of kinds) {
        const xs = lists.filter((q) => q.kind === k).slice(0, 5);
        paras.push(T(`${POI_LABEL[k]} within 5 km: ${list(xs.map((q) => `${q.name}${q.agency && k !== 'hotel' ? ` (${q.agency})` : ''}, ${km1(q.km)} km`))}.`));
      }
      table = { head: ['Nearby', 'Kind', 'Distance'], rows: lists.slice(0, 20).map((q) => [q.name, `${POI_LABEL[q.kind].replace(/s$/, '').replace(/ stop$/, ' stop')}${q.agency && q.kind !== 'hotel' ? `, ${q.agency}` : ''}`, `${km1(q.km)} km`]) };
      for (const a of new Set(lists.map((q) => q.attribution))) attributions.push(a);
      const hotels = lists.filter((q) => q.kind === 'hotel');
      if (hotels[0]) faq.push({ question: `Can you deliver the car to a hotel in ${where}?`, answer: T(`Yes, within our delivery area: give the hotel's address in your request. Hotels near the centre of ${where} include ${list(hotels.slice(0, 3).map((h) => h.name))}.`) });
    }
    if (paras.length) sections.push({ id: 'logistics', heading: `Getting around ${where}`, paras, table });
  }

  // ---------------------------------------------------------------- requirements
  {
    const paras: string[] = [];
    const bands = [...f.youngBands].sort((a, b) => a.from - b.from);
    const full = bands.length ? bands[bands.length - 1]!.to + 1 : null;
    paras.push(T(`Drivers must be ${f.minAge} or older at pickup.${bands.length ? ` A young driver fee applies by age: ${list(bands.map((b) => `${b.from} to ${b.to}${b.feeCents !== null ? `, ${money(b.feeCents)} a day` : ''}`))}${full ? `; from ${full} there is none` : ''}.` : ''}`));
    if (f.licenceClasses.length) paras.push(T(`Licence: an Ontario ${list(f.licenceClasses)} licence, valid for the whole rental.${f.otherLicenceReview ? ' A licence from another province or country, an international one with its permit included, is accepted on a request and checked by a person before we confirm.' : ''}`));
    if (f.additionalDriverBps) paras.push(T(`An additional driver costs ${pctOf(f.additionalDriverBps)} of the daily rate for each day, and meets the same rules.`));
    if (f.coverOptions.length) paras.push(T(`Third-party liability coverage is included in every rate. For damage to the car you need one of these before pickup: ${list(f.coverOptions)}.${f.deductibleCents ? ` A claim on our fleet policy costs you the ${money(f.deductibleCents)} deductible.` : ''}`));
    if (f.depositTiersCents.length) paras.push(T(`The deposit is a hold on your card, ${f.depositTiersCents.length > 1 ? `${money(Math.min(...f.depositTiersCents))} to ${money(Math.max(...f.depositTiersCents))} depending on the car` : money(f.depositTiersCents[0]!)}, never a charge.`));
    paras.push('At pickup, bring your original licence and the card you paid with.');
    if (f.noticeHours) paras.push(T(`Book at least ${f.noticeHours} ${f.noticeHours === 1 ? 'hour' : 'hours'} before pickup${p ? `, for delivery to ${where} or pickup in Toronto` : ''}.`));
    const cx = f.cancellation;
    if (cx) paras.push(T(`Cancelling: ${pctOf(cx.graceBps)} back within ${cx.graceHours} hours of booking when pickup is ${cx.earlyHours} hours or more away; ${pctOf(cx.earlyBps)} back ${cx.earlyHours} hours or more before pickup; ${pctOf(cx.midBps)} back ${cx.lateHours} to ${cx.earlyHours} hours before; nothing back later.`));
    const UNIT: Record<string, string> = { per_day: ' a day', per_hour: ' an hour', per_km: ' a km', per_item: ' each', flat: '' };
    const fees = (f.fees ?? []).filter((x) => x.amountCents > 0 && x.unit in UNIT).slice(0, 14);
    const table: DepthTable | undefined = fees.length ? { head: ['Fee', 'Amount, before HST'], rows: fees.map((x) => [x.label, `${money(x.amountCents)}${UNIT[x.unit]}${x.capCents ? `, up to ${money(x.capCents)}` : ''}`]) } : undefined;
    if (fees.length) paras.push(T(`Other standard fees, from the fee schedule: ${list(fees.map((x) => `${x.label.toLowerCase()} ${money(x.amountCents)}${UNIT[x.unit]}`))}.`));
    sections.push({ id: 'requirements', heading: `What you need to rent${where ? ` in ${where}` : ''}`, paras, table });
    faq.push({ question: `How old do I have to be to rent with ${f.brand}?`, answer: T(`${f.minAge} or older at pickup.${bands.length ? ` Drivers under ${full} pay a young driver fee${bands[0]!.feeCents !== null ? ` from ${money(Math.min(...bands.map((b) => b.feeCents ?? Infinity)))} a day` : ''}.` : ''}`) });
    if (f.licenceClasses.length) faq.push({ question: 'Which licences do you accept?', answer: T(`An Ontario ${list(f.licenceClasses)} licence.${f.otherLicenceReview ? ' Licences from other provinces and countries, with an international permit where needed, are reviewed by a person before we confirm.' : ''}`) });
  }

  // ---------------------------------------------------------------- the car's figures (car, model and type pages)
  if (x.vehicle) {
    const v = x.vehicle;
    const s = specMap(v.specs);
    const paras: string[] = [];
    const rows: string[][] = [];
    const add = (label: string, field: string, unit = '') => { const r = s.one(field); if (r) { rows.push([label, `${r.value}${unit}`]); return r; } return null; };
    const city = add('Fuel economy, city', 'fuel_city_l100', ' L/100 km'), hwy = add('Fuel economy, highway', 'fuel_highway_l100', ' L/100 km'), comb = add('Fuel economy, combined', 'fuel_combined_l100', ' L/100 km');
    add('Fuel type', 'fuel_type'); add('Tank', 'tank_l', ' L'); add('Electric use, combined', 'kwh100_combined', ' kWh/100 km'); add('Range', 'range_km', ' km');
    add('Engine', 'engine'); add('Power', 'hp', ' hp'); add('Torque', 'torque_nm', ' Nm'); add('0 to 100 km/h', 'zero_100_s', ' s'); add('Top speed', 'top_speed_kmh', ' km/h');
    add('Drivetrain', 'drivetrain'); add('Transmission', 'transmission'); add('Curb weight', 'curb_kg', ' kg'); add('Towing', 'towing_kg', ' kg');
    add('Seats', 'seats'); add('Cargo', 'cargo_l', ' L'); add('Length', 'length_mm', ' mm'); add('Width', 'width_mm', ' mm'); add('Height', 'height_mm', ' mm'); add('Wheelbase', 'wheelbase_mm', ' mm');
    add('Tire size', 'tire_size'); add('Rim size', 'rim_size'); add('NHTSA overall rating', 'safety_overall', ' stars'); add('Recalls (NHTSA)', 'recalls');
    if (city && hwy) paras.push(T(`The ${v.name} is rated ${city.value} L/100 km in the city and ${hwy.value} on the highway${comb ? `, ${comb.value} combined` : ''}.`));
    const l100 = comb ? Number(comb.value) : v.l100 ?? null;
    const kwh = s.one('kwh100_combined') ? Number(s.one('kwh100_combined')!.value) : v.kwh100 ?? null;
    const cost = costPer100({ l100, kwh100: kwh, premium: v.premium }, f.fuel);
    if (cost) {
      paras.push(T(`Estimated cost to drive 100 km: ${money(cost.cents, { cents: true })} (${cost.basis}, the price set on this site).`));
      faq.push({ question: `How much does it cost to drive the ${v.name} 100 km?`, answer: T(`About ${money(cost.cents, { cents: true })}: ${cost.basis}.`) });
    }
    const colours = s.many('paint_colour');
    if (colours.length) paras.push(T(`Factory paint colours: ${list(colours.map((c) => (c.code ? `${c.value} (${c.code})` : c.value)))}.`));
    const feats = s.many('features');
    const byTrim = new Map<string, string[]>();
    for (const r of feats) byTrim.set(r.trim || 'Every trim', [...(byTrim.get(r.trim || 'Every trim') ?? []), r.value]);
    for (const [t, xs] of byTrim) paras.push(T(`Key features, ${t}: ${list(xs.slice(0, 8))}.`));
    const seats = s.one('seats'), cargo = s.one('cargo_l');
    if (seats) faq.push({ question: `How many seats does the ${v.name} have?`, answer: `${seats.value}${cargo ? `, with ${cargo.value} L of cargo space` : ''}.` });
    if (rows.length || paras.length) {
      sections.push({ id: 'car', heading: `${v.name}: the figures`, paras, table: rows.length ? { head: ['Figure', 'Value'], rows } : undefined });
      for (const src of new Set(v.specs.map((r) => r.source_url))) attributions.push(`Specs: ${src}`);
    }
    if (v.maintenance) {
      const m = v.maintenance;
      sections.push({ id: 'maintenance', heading: `Estimated maintenance cost`, paras: [T(`About ${money(m.per_year_cents)} a year, or ${money(m.per_10k_km_cents)} per 10,000 km, for this make and segment. ${m.assumptions}`), `Source: ${m.source}.`] });
      attributions.push(`Maintenance costs: ${m.source_url}`);
    }
  }

  // ---------------------------------------------------------------- comparison checklist (alternative and versus pages)
  if (x.compare) {
    const c = x.compare;
    const all = real.length ? real : (x.fallbackCars ?? []).filter((q) => !q.isSample);
    const rows: string[][] = [];
    if (all.length) rows.push(['Daily rate', `from ${money(Math.min(...all.map((q) => q.dailyCents)))}`], ['Weekly rate', `from ${money(Math.min(...all.map((q) => q.weeklyCents)))}`], ['30-day rate', `from ${money(Math.min(...all.map((q) => q.monthlyCents)))}`]);
    const km = all.map((q) => q.kmPerDay ?? 0).filter((n) => n > 0);
    if (km.length) rows.push(['Kilometres included', `${Math.min(...km)} to ${Math.max(...km)} km a day, by car`]);
    if (f.depositTiersCents.length) rows.push(['Deposit', f.depositTiersCents.length > 1 ? `${money(Math.min(...f.depositTiersCents))} to ${money(Math.max(...f.depositTiersCents))}, a hold` : money(f.depositTiersCents[0]!)]);
    rows.push(['Youngest driver', `${f.minAge}`]);
    if (p?.inReach && p.deliveryFromCents) rows.push([`Delivery to ${where}`, `from ${money(p.deliveryFromCents)} each way`]);
    rows.push(['Longest booking', `${f.maxDays} days`]);
    if (f.coverOptions.length) rows.push(['Coverage for damage', list(f.coverOptions)]);
    sections.push({ id: 'compare', heading: c.versus ? `${f.brand}: the figures to compare` : `Renting from ${f.brand}${where ? ` in ${where}` : ''}`, paras: [
      T(`These are ${f.brand}'s own figures, from this site today. ${c.company} is named only because it is what you compared; we do not publish its prices or terms, so check them with ${c.company} before you choose.`)
    ], table: { head: [f.brand, 'Today'], rows } });
    faq.push({ question: `Is this page from ${c.company}?`, answer: `No. It is written by ${f.brand} and gives ${f.brand}'s own figures only.` });
  }

  // ---------------------------------------------------------------- related links
  {
    const links = [...(x.related?.places ?? []), ...(x.related?.cars ?? []), ...(x.related?.guides ?? [])].filter((l, i, a) => a.findIndex((y) => y.href === l.href) === i).slice(0, 24);
    if (links.length) {
      const paras: string[] = [];
      const near = (p?.nearby ?? []).filter((n) => n.km !== null && n.km !== undefined).slice(0, 8);
      if (near.length) paras.push(T(`Close to ${where}, in a straight line: ${list(near.map((n) => `${n.name}, ${n.km} km${n.km ? ` (about ${driveMinutes(n.km)} minutes)` : ''}`))}.`));
      sections.push({ id: 'related', heading: 'Related pages', paras, links });
    }
  }

  if (x.omit?.length) for (let i = sections.length - 1; i >= 0; i--) if (x.omit.includes(sections[i]!.id)) sections.splice(i, 1);
  const total = sections.reduce((n, s) => n + words(s.heading) + s.paras.reduce((m, q) => m + words(q), 0) + (s.table ? s.table.rows.flat().reduce((m, q) => m + words(q), 0) : 0)
    + (s.links ?? []).reduce((m, l) => m + words(l.label), 0), 0) + faq.reduce((n, q) => n + words(q.question) + words(q.answer), 0);
  return { sections, faq: faq.slice(0, 10), attributions: [...new Set(attributions)], words: total };
}

export { words as depthWordCount };
