// The car data writing kit (release 36, part 3; migration 2001): one set of labels, units, order and sentences for
// the figures of every car page, so each page reads the same way and shows only what its sources give. The derived
// figures (feature ratings out of 10, the parkability score) are computed here from those values with the method
// shown on the page; nothing is estimated when an input is missing. Pure, relative imports only.

export interface KitSpec { field: string; value: string; code?: string | null; trim?: string; source: string; source_url: string }

/** The figures table: [label, field, unit], in the order a reader looks for them. */
export const KIT_ROWS: ReadonlyArray<readonly [string, string, string]> = [
  ['MSRP (Canada)', 'msrp_cad', ''], ['MSRP (US)', 'msrp_usd', ''],
  ['Fuel economy, city', 'fuel_city_l100', ' L/100 km'], ['Fuel economy, highway', 'fuel_highway_l100', ' L/100 km'], ['Fuel economy, combined', 'fuel_combined_l100', ' L/100 km'],
  ['Fuel type', 'fuel_type', ''], ['Tank', 'tank_l', ' L'], ['Electric use, combined', 'kwh100_combined', ' kWh/100 km'], ['Range', 'range_km', ' km'],
  ['Battery', 'battery_kwh', ' kWh'], ['Fast charging (DC)', 'charge_dc_kw', ' kW'], ['Home charging (AC)', 'charge_ac_kw', ' kW'], ['Charging connector', 'charge_connector', ''],
  ['Engine', 'engine', ''], ['Power', 'hp', ' hp'], ['Torque', 'torque_nm', ' Nm'], ['0 to 100 km/h', 'zero_100_s', ' s'], ['Top speed', 'top_speed_kmh', ' km/h'],
  ['Drivetrain', 'drivetrain', ''], ['Transmission', 'transmission', ''], ['Body', 'body_style', ''], ['Doors', 'doors', ''],
  ['Seats', 'seats', ''], ['Passengers', 'passengers', ''], ['Suitcases', 'suitcases', ''], ['Cargo', 'cargo_l', ' L'],
  ['Length', 'length_mm', ' mm'], ['Width', 'width_mm', ' mm'], ['Height', 'height_mm', ' mm'], ['Wheelbase', 'wheelbase_mm', ' mm'], ['Ground clearance', 'ground_clearance_mm', ' mm'],
  ['Turning circle', 'turning_circle_m', ' m'], ['Curb weight', 'curb_kg', ' kg'], ['Towing', 'towing_kg', ' kg'],
  ['Tire size', 'tire_size', ''], ['Rim size', 'rim_size', ''], ['Headlights', 'headlights', ''], ['Sunroof', 'sunroof', ''], ['Apple CarPlay', 'carplay', ''], ['Android Auto', 'android_auto', ''],
  ['Production', 'production_start', ''], ['Units built', 'production_total', ''], ['North American sales', 'na_sales', ''], ['Warranty', 'warranty', ''],
  ['NHTSA overall rating', 'safety_overall', ' stars'], ['Recalls (NHTSA)', 'recalls', ''], ['Recalls (Transport Canada)', 'tc_recalls', '']
];

const list = (xs: string[]) => (xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`);
const num = (s: KitSpec | undefined) => (s && Number.isFinite(Number(s.value)) ? Number(s.value) : null);
const yes = (s: KitSpec | undefined) => (s ? /^(yes|standard|true|available|optional)/i.test(s.value) : null);
const int = (n: number) => Math.round(n).toLocaleString('en-CA');

export function kitMap(specs: KitSpec[]) {
  const one = new Map<string, KitSpec>(); const many = new Map<string, KitSpec[]>();
  for (const s of specs) { if (!one.has(s.field)) one.set(s.field, s); many.set(s.field, [...(many.get(s.field) ?? []), s]); }
  return { one: (f: string) => one.get(f), many: (f: string) => many.get(f) ?? [] };
}

/** A table value: money with its currency, years as a span, counts with separators. */
function shown(field: string, s: KitSpec, m: ReturnType<typeof kitMap>): string {
  if (field === 'msrp_cad' || field === 'msrp_usd') { const n = num(s); return n ? `$${int(n)} ${field === 'msrp_cad' ? 'CAD' : 'USD'}` : s.value; }
  if (field === 'production_start') { const e = m.one('production_end'); return e ? `${s.value} to ${e.value}` : `From ${s.value}`; }
  if (field === 'production_total' || field === 'na_sales') { const n = num(s); return n ? int(n) : s.value; }
  return s.value;
}

/** The figures table rows. */
export function kitTable(specs: KitSpec[]): string[][] {
  const m = kitMap(specs);
  const rows: string[][] = [];
  for (const [label, field, unit] of KIT_ROWS) { const s = m.one(field); if (s) rows.push([label, `${shown(field, s, m)}${unit}`]); }
  return rows;
}

/** The kit's sentences about a car (each only when its values are there). */
export function kitSentences(name: string, specs: KitSpec[]): string[] {
  const m = kitMap(specs);
  const out: string[] = [];
  const start = m.one('production_start'), end = m.one('production_end'), plants = m.many('assembly_plant').map((x) => x.value);
  if (start || plants.length) out.push(`The ${name} ${start ? `was built from ${start.value}${end ? ` to ${end.value}` : ''}` : 'is built'}${plants.length ? ` at ${list(plants.slice(0, 4))}` : ''}.`);
  const total = num(m.one('production_total')), na = num(m.one('na_sales'));
  if (total || na) out.push(`${total ? `About ${int(total)} were built` : ''}${total && na ? ', and ' : ''}${na ? `${total ? '' : 'About '}${int(na)} were sold in North America` : ''}.`);
  const markets = m.many('markets').map((x) => x.value);
  if (markets.length) out.push(`Sold in ${list(markets.slice(0, 8))}.`);
  const cad = num(m.one('msrp_cad')), usd = num(m.one('msrp_usd'));
  if (cad || usd) out.push(`Its manufacturer's suggested retail price was ${cad ? `$${int(cad)} in Canada` : ''}${cad && usd ? ' and ' : ''}${usd ? `US$${int(usd)} in the United States` : ''}.`);
  const dc = m.one('charge_dc_kw'), ac = m.one('charge_ac_kw'), conn = m.one('charge_connector'), bat = m.one('battery_kwh');
  if (dc || ac || conn) out.push(`Charging: ${[bat ? `a ${bat.value} kWh battery` : '', dc ? `up to ${dc.value} kW on a DC fast charger` : '', ac ? `${ac.value} kW at home or on a Level 2 charger` : '', conn ? `${conn.value} connector` : ''].filter(Boolean).join(', ')}.`);
  const pax = m.one('passengers') ?? m.one('seats'), bags = m.one('suitcases');
  if (pax && bags) out.push(`It takes ${pax.value} people and about ${bags.value} suitcases.`);
  const eq: string[] = [];
  const cp = yes(m.one('carplay')), aa = yes(m.one('android_auto'));
  if (cp && aa) eq.push('Apple CarPlay and Android Auto'); else if (cp) eq.push('Apple CarPlay'); else if (aa) eq.push('Android Auto');
  if (yes(m.one('sunroof'))) eq.push(`a ${/pano/i.test(m.one('sunroof')!.value) ? 'panoramic ' : ''}sunroof`);
  const hl = m.one('headlights'); if (hl) eq.push(`${hl.value.toLowerCase()} headlights`);
  if (eq.length) out.push(`Equipment: ${list(eq)}.`);
  const probs = m.many('common_problem').map((x) => x.value);
  if (probs.length) out.push(`Owners report most often about: ${list(probs.slice(0, 4))}.`);
  const items = m.many('recall_item');
  if (items.length) out.push(`Recall campaigns: ${list(items.slice(0, 6).map((x) => `${x.value}${x.code ? ` (${x.code})` : ''}`))}.`);
  return out;
}

export interface KitRating { label: string; score: number; basis: string }
const clamp = (n: number) => Math.max(1, Math.min(10, Math.round(n * 10) / 10));
const scale = (x: number, best: number, worst: number) => clamp(1 + 9 * (x - worst) / (best - worst));

/** The parkability score out of 10: shorter and narrower parks more easily (length 4,200 mm or less scores 10, 5,600
 *  mm or more 1; each 100 mm of width over 1,850 takes 1 off; a turning circle of 10.5 m or less adds 0.5, 12.5 m or
 *  more takes 1 off). Null without the length. */
export function parkability(specs: KitSpec[]): KitRating | null {
  const m = kitMap(specs);
  const len = num(m.one('length_mm'));
  if (!len) return null;
  let s = scale(len, 4200, 5600);
  const w = num(m.one('width_mm')); if (w && w > 1850) s -= (w - 1850) / 100;
  const tc = num(m.one('turning_circle_m')); if (tc) s += tc <= 10.5 ? 0.5 : tc >= 12.5 ? -1 : 0;
  return { label: 'Parkability', score: clamp(s), basis: `length ${int(len)} mm${w ? `, width ${int(w)} mm` : ''}${tc ? `, turning circle ${tc} m` : ''}` };
}

/** The feature ratings out of 10, each from the car's own figures (a rating whose inputs are missing is left out). */
export function kitRatings(specs: KitSpec[]): KitRating[] {
  const m = kitMap(specs);
  const out: KitRating[] = [];
  const l100 = num(m.one('fuel_combined_l100')), kwh = num(m.one('kwh100_combined'));
  if (kwh) out.push({ label: 'Running cost', score: scale(kwh, 14, 30), basis: `${kwh} kWh/100 km` });
  else if (l100) out.push({ label: 'Fuel economy', score: scale(l100, 4.5, 16), basis: `${l100} L/100 km combined` });
  const z = num(m.one('zero_100_s')), hp = num(m.one('hp'));
  if (z) out.push({ label: 'Performance', score: scale(z, 4, 12), basis: `0 to 100 km/h in ${z} s` });
  else if (hp) out.push({ label: 'Performance', score: scale(hp, 450, 100), basis: `${hp} hp` });
  const cargo = num(m.one('cargo_l')), seats = num(m.one('seats'));
  if (cargo) out.push({ label: 'Space', score: clamp(scale(cargo, 1000, 200) + (seats && seats >= 7 ? 1 : 0)), basis: `${cargo} L of cargo${seats ? `, ${seats} seats` : ''}` });
  const star = num(m.one('safety_overall'));
  if (star) out.push({ label: 'Crash safety', score: clamp(star * 2), basis: `NHTSA ${star} stars overall` });
  const rc = num(m.one('recalls'));
  if (rc !== null) out.push({ label: 'Recall record', score: clamp(10 - rc * 1.5), basis: `${rc} NHTSA recall campaign${rc === 1 ? '' : 's'}` });
  const cp = yes(m.one('carplay')), aa = yes(m.one('android_auto'));
  if (cp !== null && aa !== null) out.push({ label: 'Phone connection', score: cp && aa ? 10 : cp || aa ? 7 : 3, basis: [cp ? 'Apple CarPlay' : '', aa ? 'Android Auto' : ''].filter(Boolean).join(' and ') || 'Bluetooth only' });
  const pk = parkability(specs); if (pk) out.push(pk);
  return out;
}

export const RATING_METHOD = 'Ratings out of 10 are worked out by CarmaCars from the figures on this page: fuel economy from 4.5 L/100 km (10) to 16 (1), electric use from 14 kWh/100 km (10) to 30 (1); performance from 0 to 100 km/h in 4 s (10) to 12 s (1); space from 1,000 L of cargo (10) to 200 L (1), one point more with 7 seats; crash safety is the NHTSA stars times 2; recall record is 10 less 1.5 a campaign; parkability from a length of 4,200 mm (10) to 5,600 mm (1), less 1 for each 100 mm of width over 1,850 mm.';

/** The source names of the kit's values, for the page's Sources line. */
export const SOURCE_LABEL: Record<string, string> = {
  nhtsa_vpic: 'NHTSA vPIC Canadian specifications', nhtsa_recalls: 'NHTSA recalls', nhtsa_ratings: 'NHTSA 5-Star Safety Ratings', nhtsa_complaints: 'NHTSA owner complaints',
  fueleconomy_gov: 'US EPA fueleconomy.gov', oem: 'the manufacturer', open_dataset: 'an open dataset', transport_canada: 'Transport Canada recalls (Open Government Licence - Canada)', wikidata: 'Wikidata (CC0)'
};
