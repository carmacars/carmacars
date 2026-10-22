// What the vehicle pages say (migration 0092), computed from the catalog's data and the program settings. Nothing is
// written by a model: every sentence is a fact of the page's own data, so no two pages say the same thing.
// Pure functions (no imports beyond ./units.ts and the money format), unit-tested in content.test.ts.
import { costPer100km, driveLabel, engineLabel, transLabel } from './units.ts';

export type Variant = {
  id: number; epa_model: string; special?: string[]; displ: number | null; cyl: number | null; turbo: boolean; super: boolean; drive: string | null; trans: string | null;
  fuel: string; vclass: string | null; l100_city: number | null; l100_hwy: number | null; l100_comb: number | null; kwh100: number | null; ev_range_km: number | null; co2_g_km: number | null;
};
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
  l100_city: number | null; l100_hwy: number | null; l100_comb: number | null; kwh100: number | null; ev_range_km: number | null; co2_g_km: number | null; cost100: number | null };

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
      co2_g_km: avg(vs.map((x) => x.co2_g_km)),
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

/** Unique titles and descriptions: every page's own name and numbers. The brand and city come from tokens. */
export function titleFor(o: { make: string; model?: string; year?: number; trim?: string }): string {
  const name = [o.year, o.make, o.model, o.trim].filter(Boolean).join(' ');
  if (!o.model) return `${o.make} rentals in {{city}}: models, years and fuel use | {{brand}}`;
  return `Rent a ${name} in {{city}} | {{brand}}`;
}

export function descriptionFor(o: { make: string; model?: string; year?: number; trim?: string; use?: string; count?: number; firstYear?: number; lastYear?: number; cars: number; trims?: string[] }): string {
  const name = [o.year, o.make, o.model, o.trim].filter(Boolean).join(' ');
  const have = o.cars > 0 ? `${o.cars} available to rent now` : 'request one, or rent a similar car now';
  if (!o.model) return `${o.make} in {{city}}: ${o.count ?? 0} models${o.firstYear ? ` from ${o.firstYear} to ${o.lastYear}` : ''} with specs and fuel use. ${o.cars > 0 ? `${o.cars} ${o.make} ${o.cars === 1 ? 'car' : 'cars'} to rent now.` : 'Request one, or rent a similar car.'}`;
  if (!o.year) return `${name}: ${o.firstYear ? `${o.firstYear} to ${o.lastYear} specs` : 'specs'}${o.use ? `, ${o.use}` : ''}, and cost per 100 km. In {{city}}: ${have}.`;
  if (!o.trim) return `${name}${o.trims?.length ? ` (${list(o.trims.slice(0, 4))}${o.trims.length > 4 ? ' and more' : ''})` : ''}: ${o.use || 'specs'} and cost per 100 km. In {{city}}: ${have}.`;
  return `${name}: ${o.use || 'specs'}, cost per 100 km and how it compares with the other trims. In {{city}}: ${have}.`;
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
