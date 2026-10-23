// What the vehicle pages say (migration 0097), computed from the catalog's data and the program settings. Nothing is
// written by a model: every sentence is a fact of the page's own data, so no two pages say the same thing.
// Pure functions (no imports beyond ./units.ts and the money format), unit-tested in content.test.ts.
import { costPer100km, driveLabel, engineLabel, transLabel } from './units.ts';

export type Variant = {
  id: number; epa_model: string; special?: string[]; displ: number | null; cyl: number | null; turbo: boolean; super: boolean; drive: string | null; trans: string | null;
  fuel: string; vclass: string | null; l100_city: number | null; l100_hwy: number | null; l100_comb: number | null; kwh100: number | null; ev_range_km: number | null; co2_g_km: number | null;
  mpg_city?: number | null; mpg_hwy?: number | null; mpg_comb?: number | null; fuel_cost_usd?: number | null; charge240_h?: number | null; luggage_cuft?: number | null; battery_kwh?: number | null;
  /** 'nrcan': Natural Resources Canada's figures (0115), on a model year EPA has none for */
  src?: 'nrcan';
};
/** A body's Canadian dimensions (vPIC): cm and kg. */
export type Dim = { body: string; length_cm: number | null; width_cm: number | null; height_cm: number | null; wheelbase_cm: number | null; curb_kg: number | null };
export type Settings = { index_mode: 'all' | 'rules'; gas_cents: number; premium_extra_cents: number; elec_cents: number; model_min_years: number; popular_from_year: number; year_min_cars: number; trim_min_cars: number };
export type YearRow = { year: number; path: string; vclass: string | null; powertrains: number; l100_min: number | null; l100_max: number | null; kwh100_min: number | null; ev_range_max: number | null;
  fuels: string[]; drives: string[]; engines: Array<{ displ: number | null; cyl: number | null; turbo: boolean | null; fuel: string }>; trims: Array<{ slug: string; name: string }> };
export type TrimRef = { slug: string; name: string; rank: number; variant_ids: number[]; path: string };

const FUEL: Record<string, string> = { gasoline: 'Regular gas', premium: 'Premium gas', diesel: 'Diesel', hybrid: 'Hybrid (gas)', plug_in_hybrid: 'Plug-in hybrid', electric: 'Electric', e85: 'Flex fuel' };
export const fuelWord = (f: string) => FUEL[f] ?? f;
const isEv = (v: Pick<Variant, 'fuel'>) => v.fuel === 'electric';
const n1 = (x: number | null | undefined) => (x === null || x === undefined ? '' : x.toLocaleString('en-CA', { minimumFractionDigits: 1, maximumFractionDigits: 1 }));
export const dollars = (cents: number | null) => (cents === null ? '' : `$${(cents / 100).toFixed(2)}`);
export const list = (xs: string[], join = 'and') => (xs.length < 2 ? xs.join('') : `${xs.slice(0, -1).join(', ')} ${join} ${xs[xs.length - 1]}`);

/** One powertrain as the specs table shows it. */
export type Spec = { key: string; ids: number[]; engine: string; drive: string | null; trans: string | null; fuel: string; fuelWord: string;
  l100_city: number | null; l100_hwy: number | null; l100_comb: number | null; kwh100: number | null; ev_range_km: number | null; co2_g_km: number | null; cost100: number | null;
  displ: number | null; cyl: number | null; mpg_city: number | null; mpg_hwy: number | null; mpg_comb: number | null; fuel_cost_usd: number | null; charge240_h: number | null;
  luggage_cuft: number | null; battery_kwh: number | null; src?: 'nrcan' };

const avgInt = (xs: Array<number | null>) => { const ok = xs.filter((x): x is number => typeof x === 'number'); return ok.length ? Math.round(ok.reduce((a, b) => a + b, 0) / ok.length) : null; };
const maxOf = (xs: Array<number | null>) => { const ok = xs.filter((x): x is number => typeof x === 'number'); return ok.length ? Math.max(...ok) : null; };

/** The powertrains as rows, one per engine, drive, gearbox and fuel (EPA lists some twice); fuel use averaged. */
export function specs(variants: Variant[], s: Pick<Settings, 'gas_cents' | 'premium_extra_cents' | 'elec_cents'>, ids?: number[]): Spec[] {
  const pick = ids && ids.length ? variants.filter((v) => ids.includes(v.id)) : variants;
  const by = new Map<string, Variant[]>();
  for (const v of pick) {
    const engine = engineLabel({ displ: v.displ, cyl: v.cyl, turbo: v.turbo, super: v.super, ev: isEv(v), hybrid: v.fuel === 'hybrid' || v.fuel === 'plug_in_hybrid' });
    const k = [engine, driveLabel(v.drive), transLabel(v.trans), v.fuel].join('|');
    by.set(k, [...(by.get(k) ?? []), v]);
  }
  const avg = (xs: Array<number | null>) => { const ok = xs.filter((x): x is number => typeof x === 'number'); return ok.length ? Math.round((ok.reduce((a, b) => a + b, 0) / ok.length) * 10) / 10 : null; };
  return [...by].map(([key, vs]) => {
    const v = vs[0]!;
    const l100 = avg(vs.map((x) => x.l100_comb)), kwh = avg(vs.map((x) => x.kwh100));
    return {
      key, ids: vs.map((x) => x.id), engine: key.split('|')[0]!, drive: driveLabel(v.drive), trans: transLabel(v.trans), fuel: v.fuel, fuelWord: fuelWord(v.fuel),
      l100_city: avg(vs.map((x) => x.l100_city)), l100_hwy: avg(vs.map((x) => x.l100_hwy)), l100_comb: l100, kwh100: kwh,
      ev_range_km: vs.map((x) => x.ev_range_km).filter((x): x is number => typeof x === 'number').sort((a, b) => b - a)[0] ?? null,
      co2_g_km: avg(vs.map((x) => x.co2_g_km)), displ: v.displ, cyl: v.cyl,
      mpg_city: avgInt(vs.map((x) => x.mpg_city ?? null)), mpg_hwy: avgInt(vs.map((x) => x.mpg_hwy ?? null)), mpg_comb: avgInt(vs.map((x) => x.mpg_comb ?? null)),
      fuel_cost_usd: avgInt(vs.map((x) => x.fuel_cost_usd ?? null)), charge240_h: avg(vs.map((x) => x.charge240_h ?? null)),
      luggage_cuft: maxOf(vs.map((x) => x.luggage_cuft ?? null)), battery_kwh: maxOf(vs.map((x) => x.battery_kwh ?? null)),
      ...(vs.some((x) => x.src === 'nrcan') ? { src: 'nrcan' as const } : {}),
      cost100: costPer100km({ l100: l100, kwh100: kwh, gasCents: s.gas_cents, elecCents: s.elec_cents, premium: v.fuel === 'premium', premiumExtraCents: s.premium_extra_cents })
    };
  }).sort((a, b) => (a.l100_comb ?? a.kwh100 ?? 99) - (b.l100_comb ?? b.kwh100 ?? 99) || a.key.localeCompare(b.key));
}

/** "7.1 L/100 km" or "16.2 kWh/100 km": a powertrain's combined use. */
export const ratingText = (x: Pick<Spec, 'l100_comb' | 'kwh100'>) => (x.kwh100 ? `${n1(x.kwh100)} kWh/100 km` : x.l100_comb ? `${n1(x.l100_comb)} L/100 km` : '');

/** The range of combined use across powertrains: "6.9 to 8.4 L/100 km". */
export function ratingRange(sp: Spec[]): string {
  const l = sp.map((x) => x.l100_comb).filter((x): x is number => x !== null), k = sp.map((x) => x.kwh100).filter((x): x is number => x !== null);
  const r = (xs: number[], u: string) => { const a = Math.min(...xs), b = Math.max(...xs); return a === b ? `${n1(a)} ${u}` : `${n1(a)} to ${n1(b)} ${u}`; };
  return [l.length ? r(l, 'L/100 km') : '', k.length ? r(k, 'kWh/100 km') : ''].filter(Boolean).join(', or ');
}

/** "the 1.4L 4-cylinder turbo with Front-wheel drive and an 8-speed automatic" as a short powertrain name. */
export const ptName = (x: Pick<Spec, 'engine' | 'drive' | 'trans'>) => [x.engine, x.drive?.toLowerCase(), x.trans?.toLowerCase()].filter(Boolean).join(', ');

/** What changed from the year before, from the data: powertrains added or dropped, fuel use, trims. */
export function yearChanges(o: { year: number; cur: Spec[]; prevYear: number | null; prev: Spec[]; curTrims: string[]; prevTrims: string[] }): string[] {
  if (!o.prevYear) return [];
  const out: string[] = [];
  const k = (x: Spec) => `${x.engine}|${x.drive}|${x.fuel}`;
  const added = o.cur.filter((x) => !o.prev.some((p) => k(p) === k(x))), dropped = o.prev.filter((p) => !o.cur.some((x) => k(p) === k(x)));
  if (!o.prev.length && o.cur.length) out.push(`${o.year} is the first year with EPA fuel-use data for this model in our catalog.`);
  if (added.length && o.prev.length) out.push(`New for ${o.year}: ${list([...new Set(added.map(ptName))])}.`);
  if (dropped.length && o.cur.length) out.push(`Dropped after ${o.prevYear}: ${list([...new Set(dropped.map(ptName))])}.`);
  const same = o.cur.filter((x) => o.prev.some((p) => k(p) === k(x)));
  for (const x of same.slice(0, 3)) {
    const p = o.prev.find((q) => k(q) === k(x))!;
    const a = x.l100_comb ?? x.kwh100, b = p.l100_comb ?? p.kwh100, u = x.kwh100 ? 'kWh/100 km' : 'L/100 km';
    if (a !== null && b !== null && Math.abs(a - b) >= 0.2) out.push(`The ${x.engine.toLowerCase()} (${(x.drive ?? '').toLowerCase()}) is rated ${n1(a)} ${u} combined, ${a < b ? 'down' : 'up'} from ${n1(b)} in ${o.prevYear}.`);
  }
  if (!added.length && !dropped.length && same.length && out.length === 0) out.push(`The powertrains carry over from ${o.prevYear} with the same EPA ratings.`);
  const tAdd = o.curTrims.filter((t) => !o.prevTrims.includes(t)), tDrop = o.prevTrims.filter((t) => !o.curTrims.includes(t));
  if (o.prevTrims.length && tAdd.length) out.push(`Trims new in Canada for ${o.year}: ${list(tAdd)}.`);
  if (o.prevTrims.length && tDrop.length && o.curTrims.length) out.push(`No longer offered after ${o.prevYear}: ${list(tDrop)}.`);
  return out;
}

/** How a trim differs from its sibling trims of the same year, from the powertrains each one has. */
export function trimDiffs(trim: TrimRef, siblings: TrimRef[], variants: Variant[], s: Pick<Settings, 'gas_cents' | 'premium_extra_cents' | 'elec_cents'>): string[] {
  const mine = specs(variants, s, trim.variant_ids);
  const others = siblings.filter((x) => x.slug !== trim.slug);
  const out: string[] = [];
  const n = siblings.length;
  out.push(n > 1 ? `The ${trim.name} is trim ${trim.rank} of ${n} in the Canadian lineup${trim.rank === 1 ? ', the entry trim' : trim.rank === n ? ', the top of the range' : ''}.` : `The ${trim.name} is the only trim listed for this year in Canada.`);
  const key = (ids: number[]) => specs(variants, s, ids).map((x) => x.key).sort().join(';');
  const mk = key(trim.variant_ids);
  const sameAs = others.filter((o) => key(o.variant_ids) === mk).map((o) => o.name);
  const diff = others.filter((o) => key(o.variant_ids) !== mk);
  if (sameAs.length) out.push(`It shares its EPA-rated powertrain${mine.length > 1 ? 's' : ''} with the ${list(sameAs)}${diff.length ? '' : ', so the difference is in equipment, not the engine'}.`);
  for (const o of diff.slice(0, 4)) {
    const theirs = specs(variants, s, o.variant_ids);
    const onlyThem = theirs.filter((t) => !mine.some((m) => m.key === t.key)), onlyMe = mine.filter((m) => !theirs.some((t) => t.key === m.key));
    if (onlyThem.length) out.push(`The ${o.name} has the ${list(onlyThem.map(ptName))}${onlyMe.length ? `, where the ${trim.name} has the ${list(onlyMe.map(ptName))}` : ''}.`);
  }
  const drives = [...new Set(mine.map((m) => m.drive).filter(Boolean))] as string[];
  if (drives.length === 1 && others.length && others.every((o) => specs(variants, s, o.variant_ids).every((x) => x.drive !== drives[0]))) out.push(`It is the only trim with ${drives[0]!.toLowerCase()}.`);
  return out;
}

/** The cost of the trip lengths a renter thinks in, for one powertrain. */
export function tripCosts(x: Spec): Array<[string, string]> {
  if (x.cost100 === null) return [];
  return [['100 km', dollars(x.cost100)], ['A 300 km weekend', dollars(Math.round(x.cost100 * 3))], ['1,000 km', dollars(x.cost100 * 10)]];
}

/** The price used for a powertrain's cost, in words. */
export function priceBasis(x: Pick<Spec, 'fuel'>, s: Pick<Settings, 'gas_cents' | 'premium_extra_cents' | 'elec_cents'>): string {
  if (x.fuel === 'electric') return `${s.elec_cents} cents a kWh`;
  if (x.fuel === 'premium') return `$${((s.gas_cents + s.premium_extra_cents) / 100).toFixed(2)} a litre for premium`;
  return `$${(s.gas_cents / 100).toFixed(2)} a litre`;
}

/** Unique titles and descriptions: every page's own name and numbers, longest first; the page takes the first that fits
 *  (titles 70 characters, descriptions 70 to 170, after the tokens are filled). The brand and city come from tokens. */
export function titleOptions(o: { make: string; model?: string; year?: number; trim?: string }): string[] {
  const name = [o.year, o.make, o.model, o.trim].filter(Boolean).join(' ');
  if (!o.model) return [`${o.make} rentals in {{city}}: models, years and fuel use | {{brand}}`, `${o.make} rentals in {{city}}: models and fuel use | {{brand}}`, `${o.make} rentals in {{city}} | {{brand}}`];
  return [`Rent a ${name} in {{city}} | {{brand}}`, `${name} rental in {{city}} | {{brand}}`, `${name} in {{city}} | {{brand}}`, `${name} | {{brand}}`];
}
export const titleFor = (o: Parameters<typeof titleOptions>[0]) => titleOptions(o)[0]!;

export function descriptionOptions(o: { make: string; model?: string; year?: number; trim?: string; use?: string; count?: number; firstYear?: number; lastYear?: number; cars: number; trims?: string[] }): string[] {
  const name = [o.year, o.make, o.model, o.trim].filter(Boolean).join(' ');
  const have = o.cars > 0 ? `${o.cars} available to rent now` : 'request one, or rent a similar car now';
  const haveShort = o.cars > 0 ? `${o.cars} to rent now` : 'request one';
  if (!o.model) {
    const span = o.firstYear ? ` from ${o.firstYear} to ${o.lastYear}` : '';
    return [`${o.make} in {{city}}: ${o.count ?? 0} models${span} with specs and fuel use. ${o.cars > 0 ? `${o.cars} ${o.make} ${o.cars === 1 ? 'car' : 'cars'} to rent now.` : 'Request one, or rent a similar car.'}`,
      `${o.make} in {{city}}: ${o.count ?? 0} models${span}, specs and fuel use. ${o.cars > 0 ? `${o.cars} to rent now.` : 'Request one.'}`];
  }
  if (!o.year) {
    const span = o.firstYear ? `${o.firstYear} to ${o.lastYear} specs` : 'specs';
    return [`${name}: ${span}${o.use ? `, ${o.use}` : ''}, and cost per 100 km. In {{city}}: ${have}.`, `${name}: ${span}${o.use ? `, ${o.use}` : ''}. In {{city}}: ${haveShort}.`, `${name}: ${span}. In {{city}}: ${haveShort}.`];
  }
  if (!o.trim) {
    const t = o.trims?.length ? ` (${list(o.trims.slice(0, 4))}${o.trims.length > 4 ? ' and more' : ''})` : '';
    const t3 = o.trims?.length ? ` (${o.trims.length} trims)` : '';
    return [`${name}${t}: ${o.use || 'specs'} and cost per 100 km. In {{city}}: ${have}.`, `${name}${t3}: ${o.use || 'specs'} and cost per 100 km. In {{city}}: ${haveShort}.`, `${name}: ${o.use || 'specs'}. In {{city}}: ${haveShort}.`];
  }
  return [`${name}: ${o.use || 'specs'}, cost per 100 km and how it compares with the other trims. In {{city}}: ${have}.`,
    `${name}: ${o.use || 'specs'}, cost per 100 km and the other trims. In {{city}}: ${haveShort}.`, `${name}: ${o.use || 'specs'}. In {{city}}: ${haveShort}.`,
    `${name}: specs, fuel use and cost per 100 km. In {{city}}: ${haveShort}.`];
}
export const descriptionFor = (o: Parameters<typeof descriptionOptions>[0]) => descriptionOptions(o)[0]!;

/** The first option that fits (the last when none does), after the tokens are filled. */
export function fit(options: string[], fill: (s: string) => string, max: number, min = 0): string {
  const filled = options.map((x) => fill(x).replace(/\s+/g, ' ').trim());
  return filled.find((x) => x.length <= max && x.length >= min) ?? filled.find((x) => x.length <= max) ?? filled[filled.length - 1]!;
}

/** The rental questions, answered from the program settings (tokens) and the page's own data. */
export function rentalFaq(o: { name: string; cars: number; carsPath?: string; similar: number; cheapestUse?: string; cost100?: string | null; basis?: string; ev: boolean }) {
  const q: Array<{ question: string; answer: string }> = [];
  q.push(o.cars > 0
    ? { question: `Can I rent a ${o.name} in {{city}}?`, answer: `Yes. We have ${o.cars === 1 ? 'one' : o.cars} on the site now, each with its own calendar and price. Choose your dates on the car's page and send a request; nothing is charged until we confirm and you approve.` }
    : { question: `Can I rent a ${o.name} in {{city}}?`, answer: `Not from our fleet right now. Send a request for this exact car and we look for one for your dates. ${o.similar > 0 ? `Meanwhile ${o.similar === 1 ? 'a similar car is' : `${o.similar} similar cars are`} available below.` : ''}`.trim() });
  if (o.cost100) q.push({ question: `How much does fuel cost to drive the ${o.name} 100 km?`, answer: `About ${o.cost100} for ${o.ev ? 'electricity' : 'fuel'}, from the EPA combined rating of ${o.cheapestUse} at ${o.basis}. You return the car with the same ${o.ev ? 'charge' : 'fuel'} it had at pickup.` });
  q.push({ question: 'How old do I need to be to rent?', answer: '{{minAge}} or older at pickup, with an Ontario {{licence}} licence valid for the whole rental. Drivers aged {{youngA}} pay a young driver fee of {{ydA}} a day, and {{youngB}} pay {{ydB}} a day.' });
  q.push({ question: 'How much is the deposit?', answer: 'Between {{depMin}} and {{depMax}}, depending on the car. It is taken about {{depLead}} before pickup, never when you book, and the balance is released within {{releaseDays}} after you return the car.' });
  q.push({ question: 'What coverage do I need?', answer: 'Third-party liability is included in the rate. For damage to the car itself, have your own policy (OPCF 27), a credit card with rental car coverage, or add the {{brand}} Protection Plan, priced in your offer by car and driver age. At {{deductible}} or more we claim on our fleet policy and you pay the {{deductible}} deductible.' });
  q.push({ question: 'Can the car be delivered?', answer: 'Yes, anywhere, including {{airports}}. Delivery starts at {{delMin}} plus the distance from our location, priced in your offer. Collecting the car yourself is free.' });
  return q;
}

/** A deterministic studio paint for a page (so a model's pages do not all look alike), from its address. */
export function paintFor(path: string): string {
  const paints = ['white', 'silver', 'grey', 'black', 'red', 'blue'];
  let h = 0;
  for (let i = 0; i < path.length; i++) h = (h * 31 + path.charCodeAt(i)) >>> 0;
  return paints[h % paints.length]!;
}

/** The studio drawing's body shape for a body group and size class. */
export function shapeFor(group: string, vclass: string | null): string {
  const c = (vclass ?? '').toLowerCase();
  if (group === 'pickup') return 'suvlg';
  if (group === 'van') return 'van';
  if (group === 'suv') return /standard|large/.test(c) ? 'suvlg' : 'suv';
  if (group === 'sports') return /two seaters/.test(c) ? 'roadster' : 'fastback';
  if (group === 'wagon' || /small station|minicompact|subcompact/.test(c)) return 'compact';
  return 'sedan';
}

// ---------------------------------------------------------------- every figure people look up (owner, October 22)
// Only sourced figures: EPA (MPG, L/100 km, CO2, EV range, battery when EPA names it, charge time, luggage, annual fuel
// cost) and vPIC's Canadian specifications (dimensions, curb weight). A conversion says it is one. No source, no row.
export const mpgImperial = (usMpg: number) => Math.round(usMpg * 1.20095);
const cuftToL = (c: number) => Math.round(c * 28.3168);
const BODY_WORDS = /^(\d+dr|\d+d|sedan|coupe|hatch|hatchback|wagon|sportwagen|convertible|cabriolet|suv|van|cab|crew|regular|extended|pickup|truck|awd|fwd|rwd|4wd|2wd|4x4|4x2|4motion|xdrive|sdrive|quattro|4matic|\d(\.\d)?l|v\d|i\d|lwb|swb|mwb)$/i;
/** The bodies of the year a trim has: those whose special words name it ("JETTA GLI 4DR SEDAN" for the GLI), else those
 *  with no special words, else all of them. */
export function dimsFor(dims: Dim[] | undefined, model: string, trim?: string): Dim[] {
  if (!dims?.length) return [];
  const mk = model.toLowerCase().replace(/[^a-z0-9]/g, '');
  const special = (d: Dim) => {
    const words = d.body.split(/\s+/); let acc = ''; let i = 0;
    for (; i < words.length && acc !== mk && mk.startsWith(acc); i++) acc += words[i]!.toLowerCase().replace(/[^a-z0-9]/g, '');
    return words.slice(acc === mk ? i : 1).filter((w) => !BODY_WORDS.test(w)).map((w) => w.toLowerCase().replace(/[^a-z0-9]/g, '')).filter(Boolean);
  };
  const t = (trim ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
  const named = t ? dims.filter((d) => special(d).includes(t)) : [];
  if (named.length) return named;
  const plain = dims.filter((d) => special(d).length === 0);
  return plain.length ? plain : dims;
}

export type StatRow = { label: string; values: string[]; note?: string };
/** Every sourced figure of the powertrains, a column each; a row only when some powertrain has it. */
export function statRows(sp: Spec[], s: Pick<Settings, 'gas_cents' | 'premium_extra_cents' | 'elec_cents'>): StatRow[] {
  const rows: StatRow[] = [];
  const add = (label: string, f: (x: Spec) => string, note?: string) => { const v = sp.map(f); if (v.some(Boolean)) rows.push({ label, values: v.map((x) => x || ''), note }); };
  const ev = (x: Spec) => x.fuel === 'electric';
  add('Displacement', (x) => (x.displ ? `${x.displ.toFixed(1)} L` : ''));
  add('Cylinders', (x) => (x.cyl ? String(x.cyl) : ''));
  add('MPG city (US)', (x) => (x.mpg_city ? `${x.mpg_city}${ev(x) ? ' MPGe' : ''}` : ''));
  add('MPG highway (US)', (x) => (x.mpg_hwy ? `${x.mpg_hwy}${ev(x) ? ' MPGe' : ''}` : ''));
  add('MPG combined (US)', (x) => (x.mpg_comb ? `${x.mpg_comb}${ev(x) ? ' MPGe' : ''}` : ''));
  add('MPG combined (Imperial)', (x) => (x.mpg_comb && !ev(x) ? `${mpgImperial(x.mpg_comb)}` : ''), 'converted from the US figure');
  add('Battery', (x) => (x.battery_kwh ? `${x.battery_kwh} kWh` : ''));
  add('Charge at 240 V', (x) => (x.charge240_h ? `${x.charge240_h} hours` : ''));
  add('Luggage volume', (x) => (x.luggage_cuft ? `${cuftToL(x.luggage_cuft)} L (${x.luggage_cuft} cu ft)` : ''), 'litres converted from EPA\'s cubic feet');
  add('Fuel cost a year (EPA)', (x) => (x.fuel_cost_usd ? `US$${x.fuel_cost_usd.toLocaleString('en-US')}` : ''), 'EPA: 15,000 miles at its fuel prices');
  add('Fuel cost for 20,000 km', (x) => (x.cost100 !== null ? `$${Math.round((x.cost100 * 200) / 100).toLocaleString('en-CA')}` : ''), `at ${priceBasis(sp[0] ?? { fuel: 'gasoline' }, s)}`);
  return rows;
}
/** The dimensions as rows, a column per body. */
export function dimRows(d: Dim[]): StatRow[] {
  const rows: StatRow[] = [];
  const add = (label: string, f: (x: Dim) => string) => { const v = d.map(f); if (v.some(Boolean)) rows.push({ label, values: v }); };
  const cm = (x: number | null) => (x ? `${(x / 100).toFixed(2)} m (${Math.round(x / 2.54)} in)` : '');
  add('Length', (x) => cm(x.length_cm)); add('Width', (x) => cm(x.width_cm)); add('Height', (x) => cm(x.height_cm)); add('Wheelbase', (x) => cm(x.wheelbase_cm));
  add('Curb weight', (x) => (x.curb_kg ? `${x.curb_kg.toLocaleString('en-CA')} kg (${Math.round(x.curb_kg * 2.20462).toLocaleString('en-CA')} lb)` : ''));
  return rows;
}

// ---------------------------------------------------------------- city and colour pages, and the /buy twins (0097)
type Named = { make: string; model?: string; year?: number; trim?: string; city?: string; colour?: string };
const nameOf = (o: Named) => [o.year, o.make, o.model, o.trim].filter(Boolean).join(' ');
const nameNoMake = (o: Named) => [o.year, o.model, o.trim].filter(Boolean).join(' ');
const low = (s?: string) => (s ?? '').toLowerCase();
/** A term in the middle of a sentence: its phrase as stored, brands and acronyms keeping their capitals ("Uber Eats car
 *  rental", "PPF"); without a stored phrase, the name with a lowercase first letter unless its first word is an acronym. */
export const midTerm = (t: { name: string; phrase?: string }) => t.phrase?.trim() || (/^[A-Z0-9]{2,}\b/.test(t.name) ? t.name : t.name.charAt(0).toLowerCase() + t.name.slice(1));
const an = (w: string) => (/^[aeiou]/i.test(w) ? 'an' : 'a');
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
/** A place's short name for a tight title: "Toronto Pearson Airport (YYZ)" is "Pearson (YYZ)". Every option keeps the
 *  place and the colour, so no two pages' titles can meet when the long ones do not fit. */
export const shortPlace = (s: string) => s.replace(/^Toronto\s+/, '').replace(/\s+Airport\s*\((\w+)\)$/, ' ($1)');
/** Titles of a city, city and colour, or colour page, longest first. The colour page names the colour first, so it never
 *  matches the home city's city and colour page. */
export function tierTitleOptions(o: Named & { home?: string }): string[] {
  const n = nameOf(o), m = nameNoMake(o);
  // the home city's page must not take the trim page's title ("Rent a ... in Toronto")
  if (o.city && !o.colour && o.home && o.city === o.home) { const sp = shortPlace(o.city); return [`Rent a ${n} in ${o.city}: delivery and pickup`, `${n} in ${o.city}: delivery and pickup`, `${n}, ${sp} delivery`, `${m}, ${sp} delivery`]; }
  if (o.city && o.colour) { const c = low(o.colour), sp = shortPlace(o.city); return [`Rent ${an(c)} ${c} ${n} in ${o.city} | {{brand}}`, `Rent ${an(c)} ${c} ${n} in ${o.city}`, `${o.colour} ${n}, ${o.city}`, `${o.colour} ${n}, ${sp}`, `${o.colour} ${m}, ${sp}`]; }
  if (o.city) { const sp = shortPlace(o.city); return [`Rent a ${n} in ${o.city} | {{brand}}`, `Rent a ${n} in ${o.city}`, `${n} rental, ${o.city}`, `${n}, ${sp}`, `${m} rental, ${sp}`, `${m}, ${sp}`]; }
  return [`${o.colour} ${n}: specs and rental | {{brand}}`, `${o.colour} ${n}: specs and rental`, `${o.colour} ${n} | {{brand}}`, `${o.colour} ${n}`, `${o.colour} ${m} rental`];
}
export function tierDescriptionOptions(o: Named & { use?: string; km?: number | null; fee?: string | null; cars: number }): string[] {
  const n = nameOf(o);
  const have = o.cars > 0 ? `${o.cars} like it to rent now` : 'request one, or rent a similar car now';
  const deliv = o.fee ? `delivery from ${o.fee}${o.km ? ` (${o.km} km from us)` : ''}` : o.km ? `${o.km} km from us` : 'delivery or pickup';
  if (o.city && o.colour) return [`${o.colour} ${n} in ${o.city}: ${o.use || 'specs'}, ${deliv}. ${cap(have)}.`, `${o.colour} ${n} in ${o.city}: ${o.use || 'specs'}, ${deliv}.`, `${o.colour} ${n} in ${o.city}: specs, fuel use and ${deliv}.`];
  if (o.city) return [`${n} in ${o.city}: ${o.use || 'specs'}, ${deliv}, local pickup notes. ${cap(have)}.`, `${n} in ${o.city}: ${o.use || 'specs'}, ${deliv}.`, `${n} in ${o.city}: specs, fuel use and ${deliv}.`];
  return [`The ${n} in ${low(o.colour)}: ${o.use || 'specs'} and cost per 100 km. Our ${low(o.colour)} cars first; ${have}.`, `The ${n} in ${low(o.colour)}: ${o.use || 'specs'}. Our ${low(o.colour)} cars first.`, `The ${n} in ${low(o.colour)}: specs, fuel use and our cars in ${low(o.colour)} first.`];
}
/** Titles of a /buy page: "for sale" only says what the page is about; whether one is for sale is said on the page. */
export function buyTitleOptions(o: Named): string[] {
  const n = [o.colour ?? '', nameOf(o)].filter(Boolean).join(' '), m = [o.colour ?? '', nameNoMake(o)].filter(Boolean).join(' ');
  const where = o.city ? ` in ${o.city}` : '', sp = o.city ? `, ${shortPlace(o.city)}` : '';
  if (!o.model) return [`${o.make} for sale${where}: models, specs and a test drive | {{brand}}`, `${o.make} for sale${where}: models and specs | {{brand}}`, `${o.make} for sale${where}`];
  return [`${n} for sale${where}: specs and a week-long test drive`, `${n} for sale${where}: specs and a test drive`, `${n} for sale${where}: specs, recalls`, `${n} for sale${where}`, `${n} for sale${sp}`, `${m} for sale${sp}`, `Buy ${m}${sp}`];
}
export function buyDescriptionOptions(o: Named & { use?: string; recalls?: number | null; forSale: number }): string[] {
  const c = o.colour ? `${low(o.colour)} ` : '';
  const n = `${c}${nameOf(o)}`;
  const where = o.city ? ` in ${o.city}` : '';
  const sale = o.forSale > 0 ? `${o.forSale} for sale by us now` : 'none for sale by us now; rent one for a week first';
  const rc = o.recalls === null || o.recalls === undefined ? '' : o.recalls === 0 ? ', no NHTSA recalls' : `, ${o.recalls} NHTSA recall${o.recalls === 1 ? '' : 's'}`;
  return [`Buying ${an(n)} ${n}${where}? ${o.use || 'Specs'}${rc}, fuel cost a year and what to check. ${cap(sale)}.`,
    `Buying ${an(n)} ${n}${where}? ${o.use || 'Specs'}${rc} and what to check. ${cap(sale)}.`,
    `Buying ${an(n)} ${n}${where}? Specs${rc} and what to check before you buy. Rent one for a week first.`];
}

// ---------------------------------------------------------------- the term trees (/t/<term>/..., 0097)
export type TermMode = 'rental' | 'sale' | 'detailing' | 'bodyshop';
/** "Used" goes before the car; every other sale or rental term after it; a service before "for a". */
const BEFORE = new Set(['used']);
/** Titles of a page of a term's tree, longest first; every option keeps the term, the place and the colour. */
export function termTitleOptions(o: Named & { mode: TermMode; term: { slug: string; name: string } }): string[] {
  const c = o.colour ? `${low(o.colour)} ` : '';
  const n = nameOf(o), m = nameNoMake(o);
  // the shortest forms: "PPF" for "Paint protection film (PPF)", "insurance replacement" for "... rental"
  const short = /\(([^)]+)\)$/.exec(o.term.name)?.[1] ?? o.term.name.replace(/ rental$/i, '');
  const where = o.city ? ` in ${o.city}` : '', sp = o.city ? ` in ${shortPlace(o.city)}` : '';
  if (o.mode === 'detailing' || o.mode === 'bodyshop') {
    return [`${o.term.name} for ${an(c + n)} ${c}${n}${where}`, `${o.term.name}, ${c}${n}${where}`, `${o.term.name}, ${c}${n}${sp}`, `${o.term.name}, ${c}${m}${sp}`,
      `${short}, ${c}${m}${sp}`, `${short}, ${c}${m}, ${o.city ? shortPlace(o.city) : ''}`.replace(/, $/, '')].map((x) => (o.city ? x : `${x} | {{brand}}`));
  }
  if (BEFORE.has(o.term.slug)) return [`${o.term.name} ${c}${n}${where}: specs and what to check`, `${o.term.name} ${c}${n}${where}`, `${o.term.name} ${c}${n}${sp}`, `${o.term.name} ${c}${m}${sp}`];
  // the term first, as it is searched, in its own capitals ("DoorDash car rental: 2020 Toyota Corolla LE in Scarborough")
  const tail = o.mode === 'sale' ? ': specs and a test drive' : '';
  const T = o.term.name, S = /^[A-Z]{2,}$/.test(short) ? short : cap(short);
  return [`${T}: ${c}${n}${where}${o.city ? '' : ' | {{brand}}'}`, `${T}: ${c}${n}${where}${tail && !o.city ? tail : ''}`, `${T}: ${c}${n}${sp}`, `${T}: ${c}${m}${sp}`,
    `${S}: ${c}${m}${sp}`, `${S}: ${c}${m}${o.city ? `, ${shortPlace(o.city)}` : ''}`].map((x) => cap(x));
}
export function termDescriptionOptions(o: Named & { mode: TermMode; term: { slug: string; name: string; phrase?: string }; use?: string; body?: string | null; length?: string | null; forSale?: number; cars?: number; recalls?: number | null }): string[] {
  const c = o.colour ? `${low(o.colour)} ` : '';
  const n = `${c}${nameOf(o)}`, ph = midTerm(o.term), where = o.city ? ` in ${o.city}` : '';
  const facts = [o.body ? low(o.body) : '', o.length ? `${o.length} long` : '', o.use ?? ''].filter(Boolean).join(', ');
  if (o.mode === 'detailing') return [`${o.term.name} for ${an(n)} ${n}${where}${facts ? ` (${facts})` : ''}. Request a time, and rent a car from us while yours is detailed.`,
    `${o.term.name} for ${an(n)} ${n}${where}. Request a time, and rent a car while yours is detailed.`, `${o.term.name} for ${an(n)} ${n}${where}: request it, and rent a car meanwhile.`];
  if (o.mode === 'bodyshop') return [`${o.term.name} for ${an(n)} ${n}${where}${facts ? ` (${facts})` : ''}. Request it, with an insurance replacement rental while it is repaired.`,
    `${o.term.name} for ${an(n)} ${n}${where}, with an insurance replacement rental while it is repaired.`, `${o.term.name} for ${an(n)} ${n}${where}: request it, and rent a car meanwhile.`];
  if (o.mode === 'sale') {
    const sale = (o.forSale ?? 0) > 0 ? `${o.forSale} for sale by us now` : 'none for sale by us now; rent one for a week first';
    const rc = o.recalls === null || o.recalls === undefined ? '' : o.recalls === 0 ? ', no NHTSA recalls' : `, ${o.recalls} NHTSA recall${o.recalls === 1 ? '' : 's'}`;
    return [`${cap(ph)}: the ${n}${where}. ${o.use || 'Specs'}${rc} and what to check. ${cap(sale)}.`, `${cap(ph)}: the ${n}${where}. Specs${rc} and what to check. ${cap(sale)}.`, `${cap(ph)}: the ${n}${where}. Specs and a week-long test drive.`];
  }
  const have = (o.cars ?? 0) > 0 ? `${o.cars} like it to rent now in {{city}}` : 'request one, or rent a similar car now';
  return [`${cap(ph)}: the ${n}${where}. ${o.use || 'Specs'} and cost per 100 km; ${have}.`, `${cap(ph)}: the ${n}${where}. ${o.use || 'Specs'}; ${have}.`, `${cap(ph)}: the ${n}${where}. Specs, fuel use and our cars.`];
}
