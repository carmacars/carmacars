// Fixtures for the writing kit's tests: places, terms and vehicles shaped like the real reads (migrations 0095, 0097),
// and a generator of many distinct pages across every page type for the uniqueness and quality gates.
import type { Hub } from '../places/data.ts';
import { hash } from './engine.ts';
import type { KitPage } from './facts.ts';
import { hubKit, vehicleKit, type VehiclePageIn } from './pages.ts';

export const TOKENS: Record<string, string> = {
  brand: 'CarmaCars', city: 'Toronto', maxDays: '30', weekFrom: '5', minAge: '18', fullAge: '26', licence: 'G2 and G', depLead: '48 hours', notice: '2 hours',
  offerHours: '24', hst: '13%', airports: 'Toronto Pearson and Billy Bishop', delMin: '$75', reply: 'We reply within 2 hours', pet: '$150'
};

type P = { slug: string; name: string; kind: Hub['place']['kind']; country: 'CA' | 'US' | 'MX'; region: string; region_name: string; gta?: boolean; km: number; parent?: string; toronto?: boolean;
  airport?: [string, string | null, number]; nearby?: string[]; landmarks?: string[] };
export const PLACES: P[] = [
  { slug: 'toronto', name: 'Toronto', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', gta: true, km: 0, airport: ['Billy Bishop Toronto City Airport', 'YTZ', 4], nearby: ['North York', 'Scarborough', 'Etobicoke'], landmarks: ['CN Tower', 'Union Station'] },
  { slug: 'leslieville-toronto-on', name: 'Leslieville', kind: 'neighbourhood', country: 'CA', region: 'CA-ON', region_name: 'Ontario', gta: true, km: 6, parent: 'Toronto', toronto: true, airport: ['Billy Bishop Toronto City Airport', 'YTZ', 5], nearby: ['Riverdale', 'The Beaches'] },
  { slug: 'port-credit-mississauga-on', name: 'Port Credit', kind: 'neighbourhood', country: 'CA', region: 'CA-ON', region_name: 'Ontario', gta: true, km: 19, parent: 'Mississauga', airport: ['Toronto Pearson International Airport', 'YYZ', 12], nearby: ['Lorne Park', 'Mineola', 'Lakeview'] },
  { slug: 'markham-on', name: 'Markham', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', gta: true, km: 27, airport: ['Toronto Pearson International Airport', 'YYZ', 35], nearby: ['Unionville', 'Richmond Hill', 'Stouffville'], landmarks: ['Pacific Mall'] },
  { slug: 'oshawa-on', name: 'Oshawa', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', gta: true, km: 55, airport: ['Oshawa Executive Airport', 'YOO', 5], nearby: ['Whitby', 'Courtice'] },
  { slug: 'hamilton-on', name: 'Hamilton', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 60, airport: ['John C. Munro Hamilton International Airport', 'YHM', 14], nearby: ['Stoney Creek', 'Dundas', 'Ancaster'] },
  { slug: 'barrie-on', name: 'Barrie', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 85, nearby: ['Innisfil', 'Orillia'] },
  { slug: 'kingston-on', name: 'Kingston', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 240, airport: ['Kingston Norman Rogers Airport', 'YGK', 8] },
  { slug: 'ottawa-on', name: 'Ottawa', kind: 'city', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 352, airport: ['Ottawa Macdonald-Cartier International Airport', 'YOW', 10] },
  { slug: 'montreal-qc', name: 'Montreal', kind: 'city', country: 'CA', region: 'CA-QC', region_name: 'Quebec', km: 504, airport: ['Montréal-Trudeau International Airport', 'YUL', 15] },
  { slug: 'calgary-ab', name: 'Calgary', kind: 'city', country: 'CA', region: 'CA-AB', region_name: 'Alberta', km: 2700, airport: ['Calgary International Airport', 'YYC', 12] },
  { slug: 'buffalo-ny', name: 'Buffalo', kind: 'city', country: 'US', region: 'US-NY', region_name: 'New York', km: 96, airport: ['Buffalo Niagara International Airport', 'BUF', 13] },
  { slug: 'miami-fl', name: 'Miami', kind: 'city', country: 'US', region: 'US-FL', region_name: 'Florida', km: 1985, airport: ['Miami International Airport', 'MIA', 12] },
  { slug: 'guadalajara-jal', name: 'Guadalajara', kind: 'city', country: 'MX', region: 'MX-JAL', region_name: 'Jalisco', km: 3300 },
  { slug: 'ontario', name: 'Ontario', kind: 'province', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 0 }
];

/** Extra synthetic places so the sample has thousands of distinct addresses (names from parts, distances by hash). */
export function manyPlaces(n: number): P[] {
  const a = ['Maple', 'Cedar', 'Birch', 'Oak', 'Pine', 'River', 'Lake', 'Hill', 'Stone', 'Elm', 'Willow', 'Spruce', 'Ash', 'Clear', 'Fox', 'Bear', 'Eagle', 'Wolf', 'Sun', 'Moon'];
  const b = ['wood', 'field', 'brook', 'view', 'dale', 'ford', 'ridge', 'haven', 'port', 'ton', 'ville', 'crest', 'gate', 'side', 'mount'];
  const regions: Array<[string, string, 'CA' | 'US']> = [['CA-ON', 'Ontario', 'CA'], ['CA-QC', 'Quebec', 'CA'], ['CA-BC', 'British Columbia', 'CA'], ['US-NY', 'New York', 'US'], ['US-MI', 'Michigan', 'US'], ['US-TX', 'Texas', 'US']];
  const out: P[] = [];
  for (let i = 0; out.length < n; i++) {
    const h = hash(`place${i}`);
    const name = `${a[h % a.length]}${b[(h >>> 5) % b.length]}${i >= a.length * b.length ? ` ${1 + Math.floor(i / (a.length * b.length))}` : ''}`;
    const [region, rn, country] = regions[(h >>> 9) % regions.length]!;
    const km = region === 'CA-ON' ? (h >>> 12) % 400 : 300 + ((h >>> 12) % 3000);
    out.push({ slug: `${name.toLowerCase().replace(/\s+/g, '-')}-${region.toLowerCase()}`, name, kind: (h >>> 3) % 4 === 0 ? 'neighbourhood' : 'city', country, region, region_name: rn,
      gta: region === 'CA-ON' && km < 50, km, parent: (h >>> 3) % 4 === 0 ? 'Mississauga' : undefined, airport: km < 120 && h % 3 === 0 ? ['Toronto Pearson International Airport', 'YYZ', 10 + (h % 40)] : undefined,
      nearby: h % 2 ? [`${a[(h >>> 2) % a.length]}${b[(h >>> 7) % b.length]}`, `${a[(h >>> 4) % a.length]}${b[(h >>> 11) % b.length]}`] : [] });
  }
  return out;
}

type T = { slug: string; vertical: Hub['term']['vertical']; title: string; phrase: string; served?: 'yes' | 'request'; lead?: string | null; note: string; service?: [string, number | null] };
export const TERMS: T[] = [
  { slug: 'car-rental', vertical: 'rental', title: 'Car Rental', phrase: 'car rental', note: 'Rent by the day, the week or up to 30 days at a time. Drivers 18 and older with an Ontario G2 and G licence can rent.' },
  { slug: 'suv-rental', vertical: 'rental', title: 'SUV Rental', phrase: 'SUV rental', note: 'SUVs for families, luggage and winter roads. Winter tires are available as an add-on.' },
  { slug: 'uber-rental-car', vertical: 'rental', title: 'Rental Car for Uber Drivers', phrase: 'Uber rental car', note: 'Use your rental for Uber work. Tell us when you book.' },
  { slug: 'monthly-car-rental', vertical: 'rental', title: 'Monthly Car Rental', phrase: 'monthly car rental', note: 'One booking runs up to 30 days and renews with a new agreement.' },
  { slug: 'insurance-replacement-rental', vertical: 'rental', title: 'Insurance Replacement Rental', phrase: 'insurance replacement rental', note: 'When your adjuster approves a rental, we can bill your insurance company directly, and we deliver the car to you.' },
  { slug: 'airport-car-rental', vertical: 'rental', title: 'Airport Car Rental', phrase: 'airport car rental', note: 'We meet you with the car at Toronto Pearson or Billy Bishop at the time we confirm. There is no counter.' },
  { slug: 'electric-car-rental', vertical: 'rental', title: 'Electric Car Rental', phrase: 'electric car rental', note: 'Electric cars in our fleet, each with its range and charging details on its page.' },
  { slug: 'dui-car-rental', vertical: 'rental', title: 'DUI Car Rental', phrase: 'DUI car rental', note: 'Drivers with a DUI or a bad driving record can rent with us. Your eligibility and any deposit are confirmed when you book.' },
  { slug: 'van-rental', vertical: 'rental', title: 'Van Rental', phrase: 'van rental', note: 'Vans and seven-seat cars for groups, moves and airport runs with luggage.' },
  { slug: 'car-hire', vertical: 'rental', title: 'Car Hire', phrase: 'car hire', note: 'Car hire with CarmaCars works by request: you choose the car and dates, and we confirm the full price before you pay.' },
  { slug: 'chauffeur-service', vertical: 'rental', title: 'Chauffeur Service', phrase: 'chauffeur service', served: 'request', lead: 'place_request', note: 'We book a professional driver with a luxury car or van by the hour, two hours minimum.' },
  { slug: 'car-financing', vertical: 'sale', title: 'Car Financing', phrase: 'car financing', served: 'request', lead: 'finance', note: 'We are not a lender and do not arrange loans. Tell us what you need and we will help where we can.' },
  { slug: 'used-cars', vertical: 'sale', title: 'Used Cars', phrase: 'used cars', served: 'request', lead: 'buyer', note: 'Renting the same model for a week before you buy shows you how it fits your commute, your parking and your family.' },
  { slug: 'ceramic-coating', vertical: 'detailing', title: 'Ceramic Coating', phrase: 'ceramic coating', lead: 'detailing', note: 'A ceramic coating over corrected paint, for gloss and easier washing.', service: ['Paint correction and ceramic coating', null] },
  { slug: 'car-detailing', vertical: 'detailing', title: 'Car Detailing', phrase: 'car detailing', lead: 'detailing', note: 'A full detail inside and out, an interior or an exterior detail, a hand wash or a wax.', service: ['Interior and exterior detailing', 19900] },
  { slug: 'collision-repair', vertical: 'bodyshop', title: 'Collision Repair', phrase: 'collision repair', lead: 'bodyshop', note: 'Repairs after a collision, with or without an insurance claim.', service: ['Collision and accident repair', null] },
  { slug: 'dent-repair', vertical: 'bodyshop', title: 'Dent Repair', phrase: 'dent repair', lead: 'bodyshop', note: 'Dents repaired and the panel refinished when needed.', service: ['Dents, scratches and bumpers', null] },
  { slug: 'oil-change', vertical: 'bodyshop', title: 'Oil Change', phrase: 'oil change', served: 'request', lead: 'auto_service', note: 'An oil and filter change, done by a trusted shop we arrange, not by CarmaCars.' },
  { slug: 'towing', vertical: 'bodyshop', title: 'Towing', phrase: 'towing', served: 'request', lead: 'auto_service', note: 'A tow to a shop or to your home, by a towing company we arrange, not by CarmaCars. If you are in danger or blocking traffic, call 911 first.' },
  { slug: 'brake-repair', vertical: 'bodyshop', title: 'Brake Repair', phrase: 'brake repair', served: 'request', lead: 'auto_service', note: 'Brake pads, rotors and calipers checked and replaced, by a trusted shop we arrange, not by CarmaCars.' }
];

export function hubFixture(p: P, t: T): Hub {
  const inReach = p.km <= 80;
  return {
    term: { slug: t.slug, vertical: t.vertical, phrase: t.phrase, title: t.title, served: t.served ?? 'yes', landing_slug: null, lead_kind: t.lead ?? null, service_code: null, intent_note: t.note, faq: [], canonical_path: null, landing_path: null },
    path: t.vertical === 'rental' && t.slug === 'car-rental' ? `/car-rental/${p.slug}` : `/${({ rental: 'car-rental', sale: 'buy', detailing: 'detailing', bodyshop: 'body-shop' } as const)[t.vertical]}/${t.slug}/${p.slug}`,
    place: { slug: p.slug, kind: p.kind, name: p.name, country: p.country, region: p.region, region_name: p.region_name, lat: 43.6, lng: -79.4, gta: !!p.gta, landing_slug: null, iata: null, sources: { geonames: true } },
    ancestors: [{ slug: p.country.toLowerCase(), kind: 'country', name: p.country, country: p.country, region: null, region_name: null },
      ...(p.parent ? [{ slug: p.toronto ? 'toronto' : p.parent.toLowerCase(), kind: 'city' as const, name: p.parent, country: p.country, region: p.region, region_name: p.region_name }] : [])],
    children: p.kind === 'province' ? [{ slug: 'toronto', kind: 'city', name: 'Toronto', country: 'CA', region: 'CA-ON', region_name: 'Ontario' }, { slug: 'ottawa-on', kind: 'city', name: 'Ottawa', country: 'CA', region: 'CA-ON', region_name: 'Ontario' }] : [],
    gta_members: null, nearby: (p.nearby ?? []).map((n, i) => ({ slug: n.toLowerCase(), kind: 'city', name: n, country: p.country, region: p.region, region_name: p.region_name, km: 3 + i })),
    landmarks: (p.landmarks ?? []).map((n) => ({ name: n, km: 2 })), airport: p.airport ? { name: p.airport[0], iata: p.airport[1], slug: 'x', km: p.airport[2] } : null,
    origin: { lat: 43.65, lng: -79.38, label: 'our location' }, delivery: { in_reach: inReach, km: p.kind === 'province' ? null : p.km, reach_km: 80, fee_from_cents: inReach ? 7500 + p.km * 100 : null, per_km_cents: 0 },
    cars: [], counts: { car_count: 6, real_cars: 6, min_daily_cents: 4900, min_weekly_cents: null, min_monthly_cents: null, min_delivery_cents: 7500 }, real_cars: 6, disclaimer: null,
    service: t.service ? { code: 'x', name: t.service[0], description: '', from_price_cents: t.service[1] } : null, related_terms: [], rental_terms: [], indexable: true, lastmod: '2026-10-24'
  };
}

type V = { make: string; model: string; year: number; trim: string; vclass: string; group: string; fuel: string; engine: string; drive: string; trans: string; l100?: number; city?: number; hwy?: number;
  kwh?: number; range?: number; cuft?: number; len?: number; seats?: number; cars?: number };
export const VEHICLES: V[] = [
  { make: 'Toyota', model: 'Corolla', year: 2022, trim: 'LE', vclass: 'Compact Cars', group: 'car', fuel: 'gasoline', engine: '2.0L 4-cylinder', drive: 'Front-wheel drive', trans: 'Automatic (CVT)', l100: 6.9, city: 7.6, hwy: 6.0, cuft: 13, len: 463, seats: 5, cars: 2 },
  { make: 'Toyota', model: 'RAV4', year: 2023, trim: 'XLE Hybrid', vclass: 'Small Sport Utility Vehicle 4WD', group: 'suv', fuel: 'hybrid', engine: '2.5L 4-cylinder hybrid', drive: 'All-wheel drive', trans: 'Automatic (CVT)', l100: 6.0, city: 5.8, hwy: 6.3, len: 460, seats: 5, cars: 1 },
  { make: 'Tesla', model: 'Model 3', year: 2023, trim: 'Long Range', vclass: 'Midsize Cars', group: 'car', fuel: 'electric', engine: 'Electric motor', drive: 'All-wheel drive', trans: 'Automatic (single speed)', kwh: 15.2, range: 576, cuft: 23, len: 472, cars: 0 },
  { make: 'Ford', model: 'F-150', year: 2021, trim: 'XLT', vclass: 'Standard Pickup Trucks 4WD', group: 'pickup', fuel: 'gasoline', engine: '3.5L V6 turbo', drive: 'Four-wheel drive', trans: '10-speed automatic', l100: 12.4, len: 580, cars: 0 },
  { make: 'Mercedes-Benz', model: 'C-Class', year: 2022, trim: 'C 300 4MATIC', vclass: 'Compact Cars', group: 'car', fuel: 'premium', engine: '2.0L 4-cylinder turbo', drive: 'All-wheel drive', trans: '9-speed automatic', l100: 8.7, city: 10.2, hwy: 7.1, cuft: 13, len: 475, seats: 5, cars: 3 },
  { make: 'Honda', model: 'Odyssey', year: 2020, trim: 'EX-L', vclass: 'Minivan 2WD', group: 'van', fuel: 'gasoline', engine: '3.5L V6', drive: 'Front-wheel drive', trans: '10-speed automatic', l100: 10.7, len: 518, seats: 8, cars: 1 },
  { make: 'Volkswagen', model: 'Jetta', year: 2020, trim: 'Sportline', vclass: 'Compact Cars', group: 'car', fuel: 'gasoline', engine: '1.4L 4-cylinder turbo', drive: 'Front-wheel drive', trans: '8-speed automatic', l100: 6.9, cuft: 14, len: 470, cars: 0 },
  { make: 'Mazda', model: 'MX-5', year: 2019, trim: 'GS', vclass: 'Two Seaters', group: 'sports', fuel: 'premium', engine: '2.0L 4-cylinder', drive: 'Rear-wheel drive', trans: '6-speed manual', l100: 7.8, cuft: 5, len: 391, cars: 0 },
  { make: 'Hyundai', model: 'Ioniq 5', year: 2023, trim: 'Preferred AWD', vclass: 'Small Sport Utility Vehicle 4WD', group: 'suv', fuel: 'electric', engine: 'Electric motor', drive: 'All-wheel drive', trans: 'Automatic (single speed)', kwh: 19.7, range: 414, len: 463, cars: 1 },
  { make: 'Chevrolet', model: 'Malibu', year: 2022, trim: 'LS', vclass: 'Midsize Cars', group: 'car', fuel: 'gasoline', engine: '1.5L 4-cylinder turbo', drive: 'Front-wheel drive', trans: 'Automatic (CVT)', l100: 7.6, cuft: 16, len: 493, seats: 5, cars: 1 }
];
const COLOURS = ['Black', 'White', 'Silver', 'Grey', 'Red', 'Blue'];
/** The ten base vehicles across model years and trims, with figures that move a little by year (thousands of pages). */
export function manyVehicles(): V[] {
  const trims = ['LX', 'EX', 'Sport', 'Touring', 'Limited', 'Base', 'Premium', 'Platinum'];
  const out: V[] = [];
  for (const v of VEHICLES) for (let y = 2016; y <= 2025; y++) for (const [i, t] of [v.trim, ...trims.slice(0, 3)].entries()) {
    const k = 1 + ((y - 2020) * 0.01) + i * 0.03;
    out.push({ ...v, year: y, trim: t, l100: v.l100 ? Math.round(v.l100 * k * 10) / 10 : undefined, kwh: v.kwh ? Math.round(v.kwh * k * 10) / 10 : undefined,
      range: v.range ? Math.round(v.range / k) : undefined, cars: (y + i) % 3 === 0 ? 1 + (i % 2) : 0 });
  }
  // more models and makes, as the catalog has (144 makes, 1,738 models): names made from parts
  const MAKES = ['Arden', 'Belmont', 'Corvane', 'Dalton', 'Eston', 'Faro', 'Garrick', 'Halden', 'Iverson', 'Juno', 'Kestrel', 'Lorne', 'Marlow', 'Norvik', 'Orla', 'Pembroke', 'Quill', 'Rowan', 'Selby', 'Talon'];
  const MODELS = ['Aria', 'Bolt', 'Crest', 'Dune', 'Echo', 'Flint', 'Gale', 'Haven', 'Isle', 'Jet', 'Kite', 'Lynx'];
  for (const [mi, mk] of MAKES.entries()) for (let j = 0; j < 6; j++) {
    const v = VEHICLES[(mi + j) % VEHICLES.length]!;
    for (let y = 2018 + (j % 3); y <= 2024; y += 2) out.push({ ...v, make: mk, model: MODELS[(mi * 5 + j) % MODELS.length]!, year: y, trim: trims[(mi + j + y) % trims.length]!, cars: (mi + j) % 4 === 0 ? 1 : 0 });
  }
  return out;
}

export function vehicleFixture(x: V, o: { level: VehiclePageIn['level']; mode?: VehiclePageIn['mode']; term?: T; place?: P; colour?: string; base?: string }): VehiclePageIn {
  const s = (v: string) => v.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const parts = [s(x.make), ...(o.level === 'make' ? [] : [s(x.model)]), ...(['make', 'model'].includes(o.level) ? [] : [String(x.year)]), ...(['make', 'model', 'year'].includes(o.level) ? [] : [s(x.trim)])];
  const tail = o.place ? `/${o.place.slug}${o.colour ? `/${s(o.colour)}` : ''}` : o.colour ? `/colour/${s(o.colour)}` : '';
  const base = o.base ?? (o.mode === 'sale' && !o.term ? '/buy' : o.term ? `/t/${o.term.slug}` : '/cars');
  const sp = { engine: x.engine, drive: x.drive, trans: x.trans, fuel: x.fuel, l100_comb: x.l100 ?? null, l100_city: x.city ?? null, l100_hwy: x.hwy ?? null, kwh100: x.kwh ?? null,
    ev_range_km: x.range ?? null, co2_g_km: x.l100 ? Math.round(x.l100 * 23) : 0, cost100: x.l100 ? Math.round(x.l100 * 155) : x.kwh ? Math.round(x.kwh * 15) : null, mpg_comb: x.l100 ? Math.round(235.2 / x.l100) : null,
    luggage_cuft: x.cuft ?? null, battery_kwh: x.fuel === 'electric' ? 77 : null, charge240_h: x.fuel === 'electric' ? 7.5 : null, fuel_cost_usd: x.l100 ? Math.round(x.l100 * 260) : null };
  return {
    path: `${base}/${parts.join('/')}${tail}`, level: o.level, mode: o.mode ?? 'cars', make: x.make, model: o.level === 'make' ? undefined : x.model, year: ['make', 'model'].includes(o.level) ? undefined : x.year,
    trim: ['make', 'model', 'year'].includes(o.level) ? undefined : x.trim, colour: o.colour ?? null, vclass: x.vclass, bodyGroup: x.group, sp: o.level === 'make' || o.level === 'model' ? [] : [sp],
    dims: x.len ? [{ length_cm: x.len, width_cm: 182, height_cm: 145, curb_kg: 1400 }] : [], seats: x.seats ?? null, cars: x.cars ?? 0, fromDailyCents: x.cars ? 5900 : null, similar: 3,
    models: o.level === 'make' ? 12 : undefined, modelNames: o.level === 'make' ? [x.model, 'Camry', 'Highlander', 'Sienna'] : undefined, evModels: o.level === 'make' && x.fuel === 'electric' ? 2 : undefined,
    firstYear: 2015, lastYear: 2025, yearsCount: 11, bestYear: o.level === 'model' ? 2023 : undefined, trimNames: o.level === 'trim' || tierLevel(o.level) ? undefined : ['LE', 'SE', 'XLE', 'XSE'],
    trimRank: o.level === 'trim' || tierLevel(o.level) ? 2 : undefined, trimCount: o.level === 'trim' || tierLevel(o.level) ? 4 : undefined, premiumPerLitreCents: 185,
    recalls: o.mode === 'sale' || o.mode === 'bodyshop' ? (x.year % 3) : null, complaints: o.mode === 'sale' ? 40 + x.year % 50 : null, complaintTop: ['ENGINE', 'ELECTRICAL SYSTEM'], forSale: 0,
    term: o.term ? { slug: o.term.slug, name: o.term.title, phrase: o.term.phrase, kind: o.term.vertical, lead: o.term.lead, note: o.term.note } : null,
    city: o.place ? { name: o.place.name, kind: o.place.kind, km: o.place.km, feeCents: 7500, parent: o.place.parent ?? null, nearby: o.place.nearby, airport: o.place.airport?.[0] ?? null } : null
  };
}
const tierLevel = (l: string) => l === 'city' || l === 'colour' || l === 'city_colour';

/** n pages across every page type, each a distinct address. */
export function samplePages(n: number): KitPage[] {
  const places = [...PLACES, ...manyPlaces(Math.max(200, Math.ceil(n / 8)))];
  const cars = manyVehicles();
  const out: KitPage[] = [];
  const seen = new Set<string>();
  for (let i = 0; out.length < n; i++) {
    const h = hash(`sample${i}`);
    const p = places[h % places.length]!;
    const t = TERMS[(h >>> 8) % TERMS.length]!;
    const x = cars[(h >>> 4) % cars.length]!;
    const r = (h >>> 16) % 10;
    let page: KitPage;
    if (r < 5) page = hubKit(hubFixture(p, t), p.parent ? `${p.name}, ${p.parent}` : p.name, TOKENS);
    else {
      const lv = (['make', 'model', 'year', 'trim', 'city', 'colour', 'city_colour'] as const)[(h >>> 20) % 7]!;
      const mode = r === 5 || r === 6 ? 'cars' : r === 7 ? 'sale' : undefined;
      const term = mode ? (mode === 'sale' && h % 2 ? TERMS.find((y) => y.slug === 'car-financing') : undefined) : t.served === 'request' && t.lead !== 'auto_service' ? undefined : t;
      const m = mode ?? (term ? (term.vertical === 'rental' ? 'rental' : term.vertical) : 'cars');
      const colour = lv === 'colour' || lv === 'city_colour' ? COLOURS[(h >>> 24) % COLOURS.length] : undefined;
      page = vehicleKit(vehicleFixture(x, { level: lv, mode: m as VehiclePageIn['mode'], term, place: lv === 'city' || lv === 'city_colour' ? p : undefined, colour }), TOKENS);
    }
    if (seen.has(page.path)) continue;
    seen.add(page.path);
    out.push(page);
  }
  return out;
}
