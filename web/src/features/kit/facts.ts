// The facts a page gives the writing kit, and the tags its variants are chosen by (docs/changes/2026-10-24-writing-kit.md).
// Every value comes from the page's own read (the hub of migration 0095, the vehicle pages of 0097) or from a fixed,
// public fact below (road distances from Toronto, rounded and said as "about"). A value the read does not have is left
// out, and every sentence that needs it is skipped. Relative imports only (the unit tests run it in Node).
import type { KitValues } from './engine.ts';

export type PageKind =
  | 'hub-rental' | 'hub-request' | 'hub-wide' | 'hub-sale' | 'hub-detailing' | 'hub-bodyshop' | 'hub-auto'
  | 'car-make' | 'car-model' | 'car-year' | 'car-trim' | 'car-tier'
  | 'twin-rental' | 'twin-sale' | 'twin-detailing' | 'twin-bodyshop' | 'twin-auto';

export interface KitPage { kind: PageKind; path: string; values: KitValues; tags: Set<string>; tokens: Record<string, string> }

const money = (cents: number | null | undefined) => (typeof cents === 'number' && cents > 0 ? `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 })}` : undefined);
const n1 = (x: number | null | undefined) => (typeof x === 'number' && Number.isFinite(x) ? x.toLocaleString('en-CA', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) : undefined);
const int = (x: number | null | undefined) => (typeof x === 'number' && Number.isFinite(x) ? Math.round(x) : undefined);
export const listOf = (xs: string[], join = 'and') => (xs.length < 2 ? xs.join('') : `${xs.slice(0, -1).join(', ')} ${join} ${xs[xs.length - 1]}`);
function an(w: string): 'a' | 'an' {
  if (/^(8|11|18)\b|^8\d/.test(w)) return 'an';
  if (/^[A-Z]{2,}\b/.test(w)) return /^[AEFHILMNORSX]/.test(w) ? 'an' : 'a';
  if (/^(uni|use|usu|uber|one|euro)/i.test(w)) return 'a';
  if (/^(hour|honest|heir)/i.test(w)) return 'an';
  return /^[aeiou]/i.test(w) ? 'an' : 'a';
}
export const withArticle = (w: string) => `${an(w)} ${w}`;

// ---------------------------------------------------------------- places
/** Day trips from Toronto with the rounded road distance (km), for the pages of places we deliver to. */
export const TRIPS: ReadonlyArray<{ name: string; km: number; what: string; season?: 'winter' | 'summer'; border?: true }> = [
  { name: 'Niagara Falls', km: 130, what: 'the falls and the Niagara Parkway' },
  { name: 'Niagara-on-the-Lake', km: 130, what: 'the wineries and the old town' },
  { name: 'Blue Mountain', km: 160, what: 'skiing in winter and the village in summer', season: 'winter' },
  { name: 'Wasaga Beach', km: 145, what: 'a long freshwater beach on Georgian Bay', season: 'summer' },
  { name: 'Sandbanks Provincial Park', km: 230, what: 'dunes and beaches in Prince Edward County', season: 'summer' },
  { name: 'Algonquin Park', km: 270, what: 'lakes, trails and fall colours' },
  { name: 'Muskoka', km: 170, what: 'cottage country and the lakes around Gravenhurst' },
  { name: 'Huntsville', km: 215, what: 'lakes and trails at the edge of Algonquin' },
  { name: 'Kingston', km: 260, what: 'the waterfront and the Thousand Islands' },
  { name: 'Ottawa', km: 450, what: 'a long weekend in the capital' },
  { name: 'Montreal', km: 540, what: 'a long weekend in Quebec' },
  { name: 'Tobermory', km: 300, what: 'the Bruce Peninsula and its clear water', season: 'summer' },
  { name: 'Stratford', km: 150, what: 'the theatre season' },
  { name: 'Elora', km: 110, what: 'the gorge and the village' },
  { name: 'Peterborough', km: 140, what: 'the Kawartha Lakes' },
  { name: 'Grand Bend', km: 240, what: 'the beach on Lake Huron', season: 'summer' },
  { name: 'Prince Edward County', km: 220, what: 'wineries, farms and small towns' },
  { name: 'Collingwood', km: 150, what: 'the Georgian Bay shore and the ski hills', season: 'winter' },
  { name: 'Buffalo', km: 160, what: 'a day across the border', border: true }
];

export type Zone = 'toronto' | 'gta' | 'near' | 'ontario' | 'canada' | 'us' | 'mx';
const PROVINCE_WINTER = /^CA-/;
const US_WINTER = /^US-(AK|ME|NH|VT|MA|NY|MI|WI|MN|ND|SD|MT|ID|WY|CO|UT|IA|NE|PA|OH|IL|IN|CT|RI|NJ|WA|OR)$/;
const COUNTRY_NAME: Record<string, string> = { CA: 'Canada', US: 'the United States', MX: 'Mexico' };

export interface PlaceIn {
  slug: string; name: string; label: string; kind: string; country: 'CA' | 'US' | 'MX'; region: string | null; regionName: string | null;
  gta: boolean; inToronto: boolean; km: number | null; inReach: boolean; reachKm: number; feeFromCents?: number | null; originLabel?: string;
  parent?: string | null; airport?: { name: string; iata: string | null; km: number } | null; nearby?: string[]; landmarks?: string[]; within?: string[];
}

export function zoneOf(p: Pick<PlaceIn, 'country' | 'region' | 'gta' | 'inToronto' | 'inReach' | 'slug'>): Zone {
  if (p.slug === 'toronto' || p.inToronto) return 'toronto';
  if (p.gta) return 'gta';
  if (p.inReach) return 'near';
  if (p.country === 'US') return 'us';
  if (p.country === 'MX') return 'mx';
  if (p.region === 'CA-ON') return 'ontario';
  return 'canada';
}

/** The place's values and tags (the hub pages, and the vehicle pages of a place). */
export function placeFacts(p: PlaceIn, v: KitValues, tags: Set<string>) {
  const wide = ['country', 'province', 'area', 'region'].includes(p.kind);
  const zone = zoneOf(p);
  tags.add(zone).add(`kind-${p.kind}`);
  if (wide) tags.add('wide'); else tags.add('local');
  if (zone === 'toronto' || zone === 'gta' || zone === 'near') tags.add('served'); else tags.add('far');
  if (p.country !== 'CA') tags.add('usd');
  if (PROVINCE_WINTER.test(p.region ?? (p.country === 'CA' ? 'CA-' : '')) || US_WINTER.test(p.region ?? '')) tags.add('winter');
  v.place = p.name; v.placeFull = p.label; v.region = p.regionName ?? undefined; v.countryName = COUNTRY_NAME[p.country];
  if (p.parent && p.parent !== p.name) v.parentCity = p.parent;
  if (!wide && p.km !== null && p.km !== undefined) { v.km = int(p.km); tags.add('km'); if (p.km <= 900) tags.add('drivable'); }
  v.reachKm = p.reachKm;
  v.origin = p.originLabel === 'our location' ? 'our location in Toronto' : 'central Toronto';
  if (!wide && p.inReach && p.feeFromCents) { v.deliveryFrom = money(p.feeFromCents); tags.add('fee'); }
  // the nearest airport, when it is near enough to be useful (the read can return one hundreds of km away)
  if (p.airport && !wide && p.airport.km <= 75) {
    v.airport = p.airport.name; v.airportKm = int(p.airport.km); if (p.airport.iata) v.airportCode = p.airport.iata;
    tags.add('airport');
    if ((p.airport.iata === 'YYZ' || p.airport.iata === 'YTZ') && tags.has('served')) tags.add('toraero');
  }
  const near = (p.nearby ?? []).filter(Boolean).slice(0, 3);
  if (near.length) { v.nearby1 = near[0]; v.nearbyList = listOf(near); tags.add('nearby'); }
  if (near.length > 1) v.nearby2 = near[1];
  const lm = (p.landmarks ?? []).filter(Boolean).slice(0, 3);
  if (lm.length) { v.landmark1 = lm[0]; v.landmarkList = listOf(lm); tags.add('landmarks'); }
  const within = (p.within ?? []).filter(Boolean).slice(0, 4);
  if (within.length) { v.withinList = listOf(within); tags.add('within'); }
  // day trips, only where we hand over cars: two different ones for the page, chosen by its address
  if (tags.has('served') && !wide) {
    const pool = TRIPS.filter((t) => !t.border);
    const h = [...p.slug].reduce((a, c) => (a * 33 + c.charCodeAt(0)) >>> 0, 5381);
    const ia = h % pool.length, ib = (ia + 1 + ((h >>> 8) % (pool.length - 1))) % pool.length;
    const a = pool[ia]!, b = pool[ib]!;
    v.trip1 = a.name; v.trip1Km = a.km; v.trip1What = a.what; v.trip2 = b.name; v.trip2Km = b.km; v.trip2What = b.what;
    tags.add('trips');
  }
  return { zone, wide };
}

// ---------------------------------------------------------------- terms
/** The family of a search term, from its address: what kind of renter or job it is about. */
export function termFamily(slug: string, vertical: string, lead?: string | null): string[] {
  const s = slug;
  const f: string[] = [];
  const t = (re: RegExp, name: string) => { if (re.test(s)) f.push(name); };
  if (lead === 'auto_service') {
    t(/oil/, 'oil'); t(/brake/, 'brake'); t(/tire|tyre/, 'tire'); t(/winter|snow/, 'wintertire'); t(/tow/, 'tow'); t(/battery|boost|jump/, 'battery');
    t(/align/, 'align'); t(/transmission/, 'transmission'); t(/engine(?!-light)|rebuild/, 'engine'); t(/diagnos|check-engine/, 'diag'); t(/inspection/, 'inspect');
    t(/safety/, 'safety'); t(/emission|smog/, 'emissions'); t(/ac-|air-cond/, 'ac'); t(/exhaust|muffler|catalytic/, 'exhaust'); t(/suspension|shock|strut|steering/, 'suspension');
    t(/mechanic|garage|maintenance|servic|tune|mechanical/, 'mechanic');
    return f.length ? f : ['mechanic'];
  }
  if (vertical === 'detailing') {
    t(/wash/, 'wash'); t(/interior|upholstery|steam|odour|pet-hair|leather/, 'interior'); t(/exterior|wax|polish|buff/, 'exterior');
    t(/correction|polish|buff/, 'correction'); t(/ceramic/, 'coating'); t(/ppf|protection-film|clear-bra/, 'film'); t(/tint/, 'tint'); t(/wrap/, 'wrap');
    t(/mobile/, 'mobile'); t(/headlight/, 'headlight'); t(/engine-bay/, 'enginebay'); t(/full|car-detailing|auto-detailing|cleaning$/, 'full');
    return f.length ? f : ['full'];
  }
  if (vertical === 'bodyshop') {
    t(/collision|accident|frame|body-shop|auto-body|car-body|claim/, 'collision'); t(/dent|hail/, 'dent'); t(/scratch|touch/, 'scratch'); t(/bumper/, 'bumper');
    t(/paint/, 'paint'); t(/rust/, 'rust'); t(/windshield|glass/, 'glass'); t(/frame/, 'frame'); t(/claim|insurance/, 'claim'); t(/car-repair|auto-repair/, 'repair');
    return f.length ? f : ['collision'];
  }
  if (vertical === 'sale') {
    t(/financ|loan|credit/, 'finance'); t(/leas|takeover|rent-to-own/, 'lease'); t(/sell-my|trade/, 'sell'); t(/new-cars/, 'newcar'); t(/trucks/, 'truck'); t(/suvs/, 'suv');
    if (!f.some((x) => ['finance', 'lease', 'sell'].includes(x))) f.push('buyer');
    return f;
  }
  t(/uber|lyft|rideshare|eats|doordash|skip|instacart|hopp|delivery-driver|gig|amazon-flex/, 'gig');
  t(/chauffeur|with-driver|car-service|black-car|black-suv-service|executive|limo|airport-car-service/, 'chauffeur');
  t(/insurance-replacement|collision-replacement|while-car|loaner|courtesy|replacement/, 'replace');
  t(/month|long-term|subscription|lease/, 'long'); t(/weekly/, 'weekly'); t(/weekend/, 'weekend');
  t(/luxury|exotic|wedding|prom|photoshoot|uber-black/, 'luxury'); t(/wedding|prom|photoshoot/, 'event');
  t(/suv|ski/, 'suv'); t(/van|minivan|7-seater/, 'van'); t(/truck|moving/, 'truck'); t(/convertible/, 'convertible');
  t(/dui|impaired|bad-driving|high-risk|demerit|reinstatement/, 'record'); t(/g2|new-driver|under-25|18-year/, 'newdriver');
  t(/newcomer|international/, 'newcomer'); t(/no-credit|debit/, 'payment'); t(/electric/, 'ev'); t(/hybrid/, 'hybrid');
  t(/airport/, 'airportterm'); t(/delivery|near-me|pickup/, 'delivery'); t(/one-way/, 'oneway'); t(/road-trip|cross-border/, 'roadtrip'); t(/ski/, 'ski');
  t(/moving/, 'moving'); t(/corporate/, 'corporate'); t(/cross-border/, 'crossborder'); t(/pet/, 'pet'); t(/winter-tires/, 'wintertires'); t(/cheap/, 'cheap');
  t(/insurance-included/, 'carcover');
  if (!f.length) f.push('base');
  return f;
}

export interface TermIn { slug: string; title: string; phrase?: string | null; vertical: string; served?: string | null; lead?: string | null; note?: string | null; synonym?: boolean }
const midTerm = (t: TermIn) => t.phrase?.trim() || (/^[A-Z0-9]{2,}\b/.test(t.title) ? t.title : t.title.charAt(0).toLowerCase() + t.title.slice(1));
/** What the search is for, as a phrase that reads in any sentence ("Need {job} in {place}?"): a term's own words can be
 *  a place or a person ("mechanic", "body shop", "rent a car near me"), so the sentences use its family's job instead. */
const JOB: Array<[string, string]> = [
  // mechanical work we arrange
  ['oil', 'an oil change'], ['brake', 'brake work'], ['wintertire', 'a winter tire change'], ['tire', 'tire work'], ['tow', 'a tow'], ['battery', 'battery service'],
  ['align', 'a wheel alignment'], ['transmission', 'transmission work'], ['engine', 'engine work'], ['diag', 'a diagnostic check'], ['inspect', 'an inspection'],
  ['safety', 'a safety certificate'], ['emissions', 'an emissions test'], ['ac', 'air conditioning repair'], ['exhaust', 'exhaust work'], ['suspension', 'suspension work'],
  ['mechanic', 'mechanical repairs or maintenance'],
  // detailing
  ['coating', 'a ceramic coating'], ['film', 'paint protection film'], ['tint', 'window tint'], ['wrap', 'a vinyl wrap'], ['correction', 'paint correction'], ['headlight', 'headlight restoration'],
  ['enginebay', 'an engine bay clean'], ['mobile', 'mobile detailing'], ['wash', 'a hand wash'], ['interior', 'interior cleaning'], ['exterior', 'exterior detailing'], ['full', 'a full detail'],
  // body shop
  ['glass', 'windshield repair'], ['frame', 'frame repair'], ['bumper', 'bumper repair'], ['dent', 'dent repair'], ['scratch', 'scratch repair'], ['rust', 'rust repair'], ['paint', 'paint work'],
  ['claim', 'a repair through an insurance claim'], ['collision', 'collision repair'], ['repair', 'body repair'],
  // buying help
  ['finance', 'financing for a car'], ['lease', 'a lease'], ['sell', 'a way to sell or trade your car'], ['newcar', 'a car from a dealer lot'], ['buyer', 'a car to buy'],
  // renting
  ['chauffeur', 'a car with a driver'], ['gig', 'a car for rideshare or delivery work'], ['replace', 'a car while yours is off the road'], ['event', 'a car for a special occasion'],
  ['ski', 'a car for a ski trip'], ['moving', 'a vehicle for moving day'], ['crossborder', 'a car for a cross-border trip'], ['oneway', 'a one-way rental'], ['airportterm', 'a car at the airport'],
  ['luxury', 'a premium car'], ['ev', 'an electric car'], ['hybrid', 'a hybrid'], ['convertible', 'a convertible'], ['truck', 'a pickup truck'], ['van', 'a van or a seven-seat car'],
  ['suv', 'an SUV'], ['long', 'a car by the month'], ['weekly', 'a car by the week'], ['weekend', 'a car for the weekend'], ['record', 'a rental after a DUI or demerit points'],
  ['newdriver', 'a car as a new or young driver'], ['newcomer', 'a car while you settle in'], ['payment', 'a car without a credit card'], ['roadtrip', 'a car for a road trip'],
  ['corporate', 'a car for work'], ['pet', 'a car you can bring your pet in'], ['wintertires', 'a car with winter tires'], ['cheap', 'a rental on a budget'], ['delivery', 'a car brought to you'],
  ['carcover', 'a rental car'], ['base', 'a rental car']
];
export function termFacts(t: TermIn, v: KitValues, tags: Set<string>) {
  v.term = t.title; v.termLower = midTerm(t);
  const note = (t.note ?? '').replace(/\s+/g, ' ').trim();
  if (note) { v.termNote = note; tags.add('note'); }
  const fam = termFamily(t.slug, t.vertical, t.lead);
  for (const f of fam) tags.add(`t-${f}`);
  if ((t.vertical === 'sale' && (fam.includes('truck') || fam.includes('suv')))) v.job = fam.includes('truck') ? 'a truck to buy' : 'an SUV to buy';
  else v.job = JOB.find(([k]) => fam.includes(k))?.[1] ?? 'a rental car';
  if (t.synonym) tags.add('synonym');
}

// ---------------------------------------------------------------- vehicles
const LUXURY = /^(acura|alfa romeo|aston martin|audi|bentley|bmw|cadillac|ferrari|genesis|infiniti|jaguar|lamborghini|land rover|lexus|lincoln|lotus|maserati|mclaren|mercedes-benz|mercedes|polestar|porsche|rolls-royce|tesla|volvo|lucid|rivian)$/i;
export interface SpecIn { engine: string; drive: string | null; trans: string | null; fuel: string; l100_comb: number | null; l100_city: number | null; l100_hwy: number | null; kwh100: number | null;
  ev_range_km: number | null; co2_g_km: number | null; cost100: number | null; mpg_comb: number | null; luggage_cuft: number | null; battery_kwh: number | null; charge240_h: number | null; fuel_cost_usd: number | null }
export interface DimIn { length_cm: number | null; width_cm: number | null; height_cm: number | null; curb_kg: number | null }
export interface VehicleIn {
  make: string; model?: string; year?: number; trim?: string; colour?: string | null; vclass?: string | null; bodyGroup?: string | null;
  sp: SpecIn[]; dims?: DimIn[]; seats?: number | null; cars: number; fromDailyCents?: number | null; similar?: number;
  models?: number; modelNames?: string[]; evModels?: number; hybridModels?: number; firstYear?: number; lastYear?: number; yearsCount?: number; trimNames?: string[];
  trimRank?: number; trimCount?: number; bestYear?: number; premiumPerLitreCents?: number;
  recalls?: number | null; complaints?: number | null; complaintTop?: string[]; forSale?: number;
}

/** The plain word for the body: from the vehicle pages' body group and the EPA size class. */
export function bodyWord(group: string | null | undefined, vclass: string | null | undefined): { word: string; tag: string } {
  const c = (vclass ?? '').toLowerCase();
  if (group === 'pickup' || /pickup/.test(c)) return { word: 'pickup truck', tag: 'truck' };
  if (group === 'van' || /minivan/.test(c)) return /minivan/.test(c) ? { word: 'minivan', tag: 'van' } : { word: 'van', tag: 'van' };
  if (/van/.test(c)) return { word: 'van', tag: 'van' };
  if (group === 'suv' || /sport utility/.test(c)) return /small/.test(c) ? { word: 'compact SUV', tag: 'suv' } : /standard/.test(c) ? { word: 'full-size SUV', tag: 'suv' } : { word: 'SUV', tag: 'suv' };
  if (/two seaters/.test(c)) return { word: 'two-seat sports car', tag: 'sports' };
  if (group === 'sports') return { word: 'sports car', tag: 'sports' };
  if (group === 'wagon' || /station wagon/.test(c)) return { word: 'wagon', tag: 'wagon' };
  if (/minicompact|subcompact/.test(c)) return { word: 'small car', tag: 'sedan' };
  if (/compact/.test(c)) return { word: 'compact car', tag: 'sedan' };
  if (/midsize/.test(c)) return { word: 'mid-size car', tag: 'sedan' };
  if (/large/.test(c)) return { word: 'large sedan', tag: 'sedan' };
  return { word: 'car', tag: 'sedan' };
}

/** Rough plain words for EPA's luggage volume, as a renter packs. */
const cargoPlain = (l: number) => (l < 280 ? 'about a large suitcase and a couple of soft bags' : l < 400 ? 'about two large suitcases and a few soft bags'
  : l < 520 ? 'a family\'s bags for a long weekend' : 'bulky luggage, a stroller or sports gear');
const lengthSize = (m: number) => (m < 4.3 ? 'short' : m < 4.75 ? 'mid-size' : m < 5.2 ? 'on the long side' : 'long');
const lengthTip = (m: number) => (m < 4.3 ? 'Parking on city streets is easy.' : m < 4.75 ? 'It fits most condo and driveway spots.'
  : m < 5.2 ? 'Check the size of a tight parking spot.' : 'Measure your parking spot or garage first.');
const lowerFirst = (s: string) => (/^[A-Z][a-z]/.test(s) ? s.charAt(0).toLowerCase() + s.slice(1) : s);

export function vehicleFacts(x: VehicleIn, v: KitValues, tags: Set<string>) {
  v.make = x.make;
  if (LUXURY.test(x.make)) tags.add('luxury'); else tags.add('mainstream');
  if (x.model) { v.model = x.model; v.makeModel = `${x.make} ${x.model}`; }
  if (x.year) { v.year = String(x.year); tags.add('year'); }
  if (x.trim) { v.trim = x.trim; tags.add('trim'); }
  const car = [x.year, x.make, x.model, x.trim].filter(Boolean).join(' ');
  v.car = car; v.aCar = withArticle(car);
  if (x.colour) { v.colour = x.colour.toLowerCase(); v.colourCar = `${x.colour.toLowerCase()} ${car}`; v.aColourCar = withArticle(`${x.colour.toLowerCase()} ${car}`); tags.add('colour'); }
  // the body only when the read names one (a make page has none)
  if (x.bodyGroup || x.vclass) { const b = bodyWord(x.bodyGroup, x.vclass); v.body = b.word; v.aBody = withArticle(b.word); tags.add(b.tag); }
  if (x.vclass) v.vclass = x.vclass.toLowerCase();
  if (x.cars > 0) { v.cars = x.cars; tags.add('cars'); } else tags.add('nocars');
  if (x.similar && x.similar > 0) { v.similar = x.similar; tags.add('similar'); }
  if (x.fromDailyCents) { v.fromDaily = money(x.fromDailyCents); tags.add('price'); }
  if (x.seats) { v.seats = x.seats; tags.add('seats'); if (x.seats >= 7) tags.add('seats7'); }
  if (x.models) { v.models = x.models; }
  if (x.modelNames?.length) v.modelList = listOf(x.modelNames.slice(0, 5));
  if (x.evModels) { v.evModels = x.evModels; tags.add('make-ev'); }
  if (x.hybridModels) { v.hybridModels = x.hybridModels; tags.add('make-hybrid'); }
  if (x.firstYear && x.lastYear) { v.firstYear = String(x.firstYear); v.lastYear = String(x.lastYear); if (x.firstYear !== x.lastYear) tags.add('span'); }
  if (x.yearsCount) v.yearsCount = x.yearsCount;
  if (x.bestYear) v.bestYear = String(x.bestYear);
  if (x.trimNames?.length) { v.trimList = listOf(x.trimNames.slice(0, 5)); v.trimCount = x.trimNames.length; tags.add('trims'); if (x.trimNames.length > 1) tags.add('manytrims'); }
  if (x.trimRank && x.trimCount) { v.trimRank = x.trimRank; v.trimOf = x.trimCount; tags.add(x.trimCount === 1 ? 'onlytrim' : x.trimRank === 1 ? 'entrytrim' : x.trimRank === x.trimCount ? 'toptrim' : 'midtrim'); }
  // the powertrain: the most efficient one (the specs table lists every one)
  const sp = x.sp;
  if (sp.length) {
    v.powertrains = sp.length; tags.add(sp.length > 1 ? 'manypt' : 'onept');
    const s = sp[0]!;
    v.engine = lowerFirst(s.engine); if (s.drive) v.drive = lowerFirst(s.drive); if (s.trans) v.trans = lowerFirst(s.trans);
    const fuels = new Set(sp.map((p) => p.fuel));
    const fuel = s.fuel;
    tags.add(fuel === 'electric' ? 'ev' : fuel === 'plug_in_hybrid' ? 'phev' : fuel === 'hybrid' ? 'hybrid' : fuel === 'diesel' ? 'diesel' : fuel === 'premium' ? 'premium' : 'gas');
    if (fuel !== 'electric') tags.add('burns');
    v.energy = fuel === 'electric' ? 'electricity' : 'fuel'; v.level = fuel === 'electric' ? 'charge' : 'fuel';
    if ([...fuels].some((f) => f === 'electric')) tags.add('has-ev');
    if ([...fuels].some((f) => f === 'hybrid' || f === 'plug_in_hybrid')) tags.add('has-hybrid');
    const d = (s.drive ?? '').toLowerCase();
    tags.add(/all/.test(d) ? 'awd' : /four|4/.test(d) ? '4wd' : /front/.test(d) ? 'fwd' : /rear/.test(d) ? 'rwd' : 'drive-unknown');
    const tr = (s.trans ?? '').toLowerCase();
    if (/cvt|variable/.test(tr)) tags.add('cvt'); else if (/manual/.test(tr)) tags.add('manual'); else if (tr) tags.add('auto');
    if (/turbo/i.test(s.engine)) tags.add('turbo');
    if (s.l100_comb) {
      v.l100 = n1(s.l100_comb); v.litres300 = int(s.l100_comb * 3); tags.add('l100');
      if (s.l100_city && s.l100_hwy) { v.l100City = n1(s.l100_city); v.l100Hwy = n1(s.l100_hwy); tags.add('cityhwy'); }
      if (s.l100_comb <= 6.5) tags.add('thrifty'); else if (s.l100_comb >= 11) tags.add('thirsty');
    }
    if (s.kwh100) { v.kwh100 = n1(s.kwh100); v.kwh300 = int(s.kwh100 * 3); tags.add('kwh'); }
    if (s.ev_range_km) {
      v.range = s.ev_range_km; tags.add(fuel === 'electric' ? 'range' : 'phevrange');
      const reach = TRIPS.filter((t) => !t.border && t.km <= s.ev_range_km! * 0.8).sort((a, b) => b.km - a.km)[0];
      if (reach && fuel === 'electric') { v.rangeTrip = reach.name; v.rangeTripKm = reach.km; tags.add('rangetrip'); }
    }
    if (s.mpg_comb && fuel !== 'electric') v.mpg = s.mpg_comb;
    if (s.cost100 !== null && s.cost100 > 0) { v.cost100 = money(s.cost100); v.cost300 = money(Math.round(s.cost100 * 3)); v.cost1000 = money(s.cost100 * 10); tags.add('cost'); }
    if (s.luggage_cuft) { const l = Math.round(s.luggage_cuft * 28.3168); v.cargoL = l; v.cargoPlain = cargoPlain(l); tags.add('cargo'); }
    if (s.battery_kwh) { v.battery = s.battery_kwh; tags.add('battery'); }
    if (s.charge240_h) { v.charge240 = n1(s.charge240_h); tags.add('charge'); }
    if (s.co2_g_km !== null && s.co2_g_km > 0) { v.co2 = int(s.co2_g_km); tags.add('co2'); }
    if (s.fuel_cost_usd) { v.fuelYearUsd = `US$${s.fuel_cost_usd.toLocaleString('en-US')}`; tags.add('fuelyear'); }
    if (x.premiumPerLitreCents && fuel === 'premium') v.premiumPrice = `$${(x.premiumPerLitreCents / 100).toFixed(2)} a litre`;
  } else tags.add('nospecs');
  const d = x.dims?.find((y) => y.length_cm);
  if (d?.length_cm) { const m = d.length_cm / 100; v.lengthM = m.toFixed(2); v.lengthSize = lengthSize(m); v.lengthTip = lengthTip(m); tags.add('length'); if (m >= 5.2) tags.add('long'); if (m < 4.3) tags.add('short'); }
  if (d?.width_cm) v.widthM = (d.width_cm / 100).toFixed(2);
  if (d?.curb_kg) { v.weightKg = d.curb_kg; tags.add('weight'); }
  if (x.recalls !== null && x.recalls !== undefined) { v.recalls = x.recalls; tags.add(x.recalls > 0 ? 'recalls' : 'norecalls'); }
  if (x.complaints !== null && x.complaints !== undefined && x.complaints > 0) { v.complaints = x.complaints; tags.add('complaints'); if (x.complaintTop?.length) v.complaintTop = listOf(x.complaintTop.slice(0, 3).map((c) => c.toLowerCase())); }
  if (x.forSale && x.forSale > 0) { v.forSale = x.forSale; tags.add('forsale'); } else tags.add('notforsale');
}

/** The tags every page has: its kind and its level. */
export function baseTags(kind: PageKind, extra: string[] = []): Set<string> {
  const t = new Set<string>([kind, kind.split('-')[0]!, ...extra]);
  return t;
}
