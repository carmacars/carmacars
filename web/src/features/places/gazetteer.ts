// The places of the hub pages (migration 0095), built from three sources: GeoNames (CC BY 4.0) for the tree of
// countries, provinces and states, regions, cities, airports and landmarks; OpenStreetMap place nodes (ODbL) for the
// neighbourhoods and towns GeoNames lacks; the US Census Gazetteer (public domain) to confirm and complete US cities.
// No imports: the places workflow (web/scripts/places/build.mjs) and the unit test run it in Node.
//
// What it decides, all from the data:
// - kind: provinces and states (GeoNames ADM1), regions (ADM2), cities and towns (populated places), neighbourhoods
//   (GeoNames PPLX, OpenStreetMap suburb, quarter, neighbourhood and borough, and small populated places inside a
//   large city's radius), airports (with an IATA code), landmarks (malls, stadiums, museums and the like);
// - duplicates: an OpenStreetMap or Census place with the same name close to a GeoNames place is the same place;
// - parents: a city under its region (else its province), a neighbourhood under the nearest large city around it,
//   an airport under its region, a landmark under the neighbourhood around it (1.5 km) or the nearest city;
// - slugs: unique, readable (kingston-on, port-credit-mississauga-on, yyz-airport).

export type Kind = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8; // country, province, region, area, city, neighbourhood, airport, landmark
export const KIND_NAME: Record<Kind, string> = { 1: 'country', 2: 'province', 3: 'region', 4: 'area', 5: 'city', 6: 'neighbourhood', 7: 'airport', 8: 'landmark' };
export const FLAG = { gta: 1, geonames: 2, osm: 4, census: 8, curated: 16, fixture: 32 } as const;

export interface StagedPlace {
  src_id: number; kind: Kind; flags: number; region_code: string | null; country: 'CA' | 'US' | 'MX';
  lat: number; lng: number; population: number | null; parent_src_id: number | null; slug: string; name: string; iata: string | null;
}

// ------------------------------------------------------------------ regions
const CA_ADMIN1: Record<string, string> = { '01': 'AB', '02': 'BC', '03': 'MB', '04': 'NB', '05': 'NL', '07': 'NS', '08': 'ON', '09': 'PE', '10': 'QC', '11': 'SK', '12': 'YT', '13': 'NT', '14': 'NU' };
// Mexico's states by name (GeoNames admin1 codes are numbers; the ISO 3166-2 codes are letters)
const MX_BY_NAME: Array<[RegExp, string]> = [
  [/^aguascalientes/, 'AGU'], [/^baja california sur/, 'BCS'], [/^baja california/, 'BCN'], [/^campeche/, 'CAM'], [/^chiapas/, 'CHP'], [/^chihuahua/, 'CHH'],
  [/^coahuila/, 'COA'], [/^colima/, 'COL'], [/^(distrito federal|mexico city|ciudad de mexico)/, 'CMX'], [/^durango/, 'DUR'], [/^guanajuato/, 'GUA'], [/^guerrero/, 'GRO'],
  [/^hidalgo/, 'HID'], [/^jalisco/, 'JAL'], [/^(mexico|estado de mexico|state of mexico)$/, 'MEX'], [/^michoacan/, 'MIC'], [/^morelos/, 'MOR'], [/^nayarit/, 'NAY'],
  [/^nuevo leon/, 'NLE'], [/^oaxaca/, 'OAX'], [/^puebla/, 'PUE'], [/^queretaro/, 'QUE'], [/^quintana roo/, 'ROO'], [/^san luis potosi/, 'SLP'], [/^sinaloa/, 'SIN'],
  [/^sonora/, 'SON'], [/^tabasco/, 'TAB'], [/^tamaulipas/, 'TAM'], [/^tlaxcala/, 'TLA'], [/^veracruz/, 'VER'], [/^yucatan/, 'YUC'], [/^zacatecas/, 'ZAC']];
/** GeoNames files of US territories, loaded as regions of the United States. */
export const US_TERRITORIES = ['PR', 'VI', 'GU', 'AS', 'MP'] as const;

export const ascii = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '');
export const slugify = (s: string) => ascii(s).toLowerCase().replace(/['’.]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
export const norm = (s: string) => ascii(s).toLowerCase().replace(/\bsainte\b/g, 'ste').replace(/\bsaint\b/g, 'st').replace(/\bmount\b/g, 'mt').replace(/[^a-z0-9]+/g, ' ').trim();

/** The ISO region code (CA-ON, US-NY, MX-JAL) of a GeoNames feature, or null. */
export function regionCode(country: string, admin1: string, admin1Name?: string): string | null {
  if ((US_TERRITORIES as readonly string[]).includes(country)) return `US-${country}`;
  if (country === 'CA') return CA_ADMIN1[admin1] ? `CA-${CA_ADMIN1[admin1]}` : null;
  if (country === 'US') return /^[A-Z]{2}$/.test(admin1) ? `US-${admin1}` : null;
  if (country === 'MX') {
    const n = ascii(admin1Name ?? '').toLowerCase();
    const hit = MX_BY_NAME.find(([re]) => re.test(n));
    return hit ? `MX-${hit[1]}` : null;
  }
  return null;
}
const countryOf = (cc: string): 'CA' | 'US' | 'MX' | null => (cc === 'CA' || cc === 'US' || cc === 'MX' ? cc : (US_TERRITORIES as readonly string[]).includes(cc) ? 'US' : null);

// ------------------------------------------------------------------ distances and a grid
export function km(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const r = Math.PI / 180, dLat = (bLat - aLat) * r, dLng = (bLng - aLng) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(aLat * r) * Math.cos(bLat * r) * Math.sin(dLng / 2) ** 2;
  return 12742 * Math.asin(Math.min(1, Math.sqrt(h)));
}
class Grid<T extends { lat: number; lng: number }> {
  private cells = new Map<string, T[]>();
  private size: number;
  constructor(size = 0.5) { this.size = size; }
  private key(lat: number, lng: number) { return `${Math.floor(lat / this.size)}:${Math.floor(lng / this.size)}`; }
  add(x: T) { const k = this.key(x.lat, x.lng); (this.cells.get(k) ?? this.cells.set(k, []).get(k)!).push(x); }
  near(lat: number, lng: number, rings = 1): T[] {
    const out: T[] = []; const a = Math.floor(lat / this.size), b = Math.floor(lng / this.size);
    for (let i = -rings; i <= rings; i++) for (let j = -rings; j <= rings; j++) out.push(...(this.cells.get(`${a + i}:${b + j}`) ?? []));
    return out;
  }
}

// ------------------------------------------------------------------ the sources
export interface GnFeature { id: number; name: string; lat: number; lng: number; fclass: string; fcode: string; cc: string; admin1: string; admin2: string; population: number }
/** One line of a GeoNames country file (tab separated, 19 columns). */
export function parseGeonamesLine(line: string): GnFeature | null {
  const c = line.split('\t');
  if (c.length < 15) return null;
  const id = Number(c[0]); const lat = Number(c[4]); const lng = Number(c[5]);
  if (!id || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  return { id, name: c[1]!, lat, lng, fclass: c[6]!, fcode: c[7]!, cc: c[8]!, admin1: c[10] ?? '', admin2: c[11] ?? '', population: Number(c[14]) || 0 };
}
export interface OsmNode { id: number; name: string; place: string; lat: number; lng: number; population: number }
/** One line of `osmium export -f geojsonseq` of place nodes (with --add-unique-id=type_id). */
export function parseOsmLine(line: string): OsmNode | null {
  const t = line.replace(/^\x1e/, '').trim();
  if (!t) return null;
  try {
    const f = JSON.parse(t) as { id?: string | number; geometry?: { type: string; coordinates: [number, number] }; properties?: Record<string, string> };
    if (f.geometry?.type !== 'Point') return null;
    const p = f.properties ?? {};
    const name = p['name:en'] && /^[\x20-\x7e]+$/.test(p['name:en']) && !p.name ? p['name:en'] : p.name;
    const id = Number(String(f.id ?? p['@id'] ?? '').replace(/^n/, ''));
    if (!name || !p.place || !id) return null;
    return { id, name, place: p.place, lng: f.geometry.coordinates[0], lat: f.geometry.coordinates[1], population: Number(String(p.population ?? '').replace(/[^0-9]/g, '')) || 0 };
  } catch { return null; }
}
export interface CensusPlace { geoid: number; usps: string; name: string; active: boolean; lat: number; lng: number }
const LSAD = / (city and borough|city|town|village|borough|CDP|municipality|plantation|comunidad|zona urbana|urban county|consolidated government|metropolitan government|unified government|\(balance\))+$/i;
/** One line of the Census Gazetteer national places file (tab separated, with its header). */
export function parseCensusLine(line: string, header: string[]): CensusPlace | null {
  const c = line.split('\t').map((x) => x.trim());
  const at = (k: string) => c[header.indexOf(k)] ?? '';
  const lat = Number(at('INTPTLAT')); const lng = Number(at('INTPTLONG'));
  if (!at('GEOID') || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  let name = at('NAME');
  for (let i = 0; i < 3; i++) name = name.replace(LSAD, '');
  return { geoid: Number(at('GEOID')), usps: at('USPS'), name: name.trim(), active: at('FUNCSTAT') === 'A', lat, lng };
}

// ------------------------------------------------------------------ the build
const CITY_CODES = new Set(['PPL', 'PPLA', 'PPLA2', 'PPLA3', 'PPLA4', 'PPLA5', 'PPLC', 'PPLG', 'PPLL', 'PPLS', 'PPLF', 'PPLR']);
const SEAT_CODES = new Set(['PPLA', 'PPLA2', 'PPLC']);
const LANDMARK_CODES = new Set(['MALL', 'STDM', 'MUS', 'ZOO', 'AMUS', 'UNIV', 'HSTS', 'MNMT', 'THTR', 'TOWR', 'CSTL', 'OPRA']);
const OSM_CITY = new Set(['city', 'town', 'village', 'hamlet']);
const OSM_HOOD = new Set(['suburb', 'quarter', 'neighbourhood', 'borough']);
/** How far a large city reaches around its centre, for the places inside it (km). */
export const cityRadius = (pop: number) => Math.min(30, Math.max(3, 0.5 * Math.sqrt(pop / 1000)));

interface Work { src_id: number; kind: Kind; flags: number; cc: string; country: 'CA' | 'US' | 'MX'; admin1: string; admin2: string; region_code: string | null;
  lat: number; lng: number; population: number; name: string; iata: string | null; fcode: string; seat: boolean; incorporated: boolean; parent: number | null }

export interface BuildInput {
  geonames: Iterable<GnFeature>;
  admin1Names?: Record<string, string>;      // "MX.14" -> "Jalisco"
  iata?: Record<number, string>;             // GeoNames id -> IATA code
  osm?: Iterable<OsmNode>;
  census?: Iterable<CensusPlace>;
  regions?: string[] | null;                 // only these regions (CA-ON, US-NY); null: all
  countryIds?: Record<string, number>;       // country code -> GeoNames id (the countries and the territories)
  fixture?: boolean;
}
export interface BuildResult { places: StagedPlace[]; counts: Record<string, Record<string, number>>; merged: { osm: number; census: number } }

export function buildPlaces(inp: BuildInput): BuildResult {
  const want = (rc: string | null) => !!rc && (!inp.regions || inp.regions.includes(rc));
  const base = inp.fixture ? FLAG.fixture : 0;
  const all: Work[] = [];
  const adm1 = new Map<string, Work>(); const adm2 = new Map<string, Work>();
  const countryIds = { CA: 6251999, US: 6252001, MX: 3996063, ...(inp.countryIds ?? {}) } as Record<string, number>;
  // GeoNames
  for (const f of inp.geonames) {
    const country = countryOf(f.cc);
    if (!country) continue;
    const rc = regionCode(f.cc, f.admin1, inp.admin1Names?.[`${f.cc}.${f.admin1}`] ?? (f.fcode === 'ADM1' ? f.name : undefined));
    const w = (kind: Kind, extra: Partial<Work> = {}): Work => ({ src_id: f.id, kind, flags: base | FLAG.geonames, cc: f.cc, country, admin1: f.admin1, admin2: f.admin2, region_code: rc,
      lat: f.lat, lng: f.lng, population: f.population, name: f.name, iata: null, fcode: f.fcode, seat: SEAT_CODES.has(f.fcode), incorporated: false, parent: null, ...extra });
    const territory = (US_TERRITORIES as readonly string[]).includes(f.cc);
    if (f.fclass === 'A' && f.fcode === 'ADM1') { if (!want(rc)) continue; const x = w(territory ? 3 : 2); all.push(x); adm1.set(`${f.cc}.${f.admin1}`, x); continue; }
    if (f.fclass === 'A' && f.fcode === 'ADM2') { if (!want(rc)) continue; const x = w(3); all.push(x); adm2.set(`${f.cc}.${f.admin1}.${f.admin2}`, x); continue; }
    if (!want(rc)) continue;
    if (f.fclass === 'P' && f.fcode === 'PPLX') { all.push(w(6)); continue; }
    if (f.fclass === 'P' && CITY_CODES.has(f.fcode)) { all.push(w(5)); continue; }
    if (f.fclass === 'S' && f.fcode === 'AIRP' && inp.iata?.[f.id]) { all.push(w(7, { iata: inp.iata[f.id]! })); continue; }
    if (f.fclass === 'S' && LANDMARK_CODES.has(f.fcode)) { all.push(w(8)); continue; }
  }
  // the territories themselves are provinces-level regions of the United States
  for (const t of US_TERRITORIES) {
    if (!want(`US-${t}`) || !countryIds[t]) continue;
    const any = all.find((x) => x.cc === t);
    if (!any) continue;
    const x: Work = { src_id: countryIds[t]!, kind: 2, flags: base | FLAG.geonames, cc: t, country: 'US', admin1: t, admin2: '', region_code: `US-${t}`, lat: any.lat, lng: any.lng,
      population: 0, name: ({ PR: 'Puerto Rico', VI: 'U.S. Virgin Islands', GU: 'Guam', AS: 'American Samoa', MP: 'Northern Mariana Islands' } as Record<string, string>)[t]!, iata: null, fcode: 'TERR', seat: false, incorporated: false, parent: null };
    all.push(x); adm1.set(`${t}.`, x);
  }
  const placesGrid = new Grid<Work>(0.5);
  for (const x of all) if (x.kind === 5 || x.kind === 6) placesGrid.add(x);
  const nearestNamed = (name: string, lat: number, lng: number, maxKm: number, kinds: Kind[]) => {
    const n = norm(name); let best: Work | null = null; let bd = maxKm;
    for (const x of placesGrid.near(lat, lng)) if (kinds.includes(x.kind) && norm(x.name) === n) { const d = km(lat, lng, x.lat, x.lng); if (d <= bd) { bd = d; best = x; } }
    return best;
  };
  const nearestAny = (lat: number, lng: number, country: string | null) => {
    let best: Work | null = null; let bd = Infinity;
    for (const x of placesGrid.near(lat, lng, 2)) if ((country === null || x.country === country) && x.flags & FLAG.geonames) { const d = km(lat, lng, x.lat, x.lng); if (d < bd) { bd = d; best = x; } }
    return best;
  };
  // OpenStreetMap: the same place close by is a duplicate; otherwise a new town or neighbourhood in the region of the nearest GeoNames place
  let mergedOsm = 0;
  for (const o of inp.osm ?? []) {
    const city = OSM_CITY.has(o.place), hood = OSM_HOOD.has(o.place);
    if (!city && !hood) continue;
    const dup = nearestNamed(o.name, o.lat, o.lng, city ? 10 : 3, [5, 6]);
    if (dup) { dup.flags |= FLAG.osm; dup.population = Math.max(dup.population, o.population); mergedOsm++; continue; }
    const near = nearestAny(o.lat, o.lng, null);
    if (!near || !want(near.region_code) || km(o.lat, o.lng, near.lat, near.lng) > 60) continue;
    const x: Work = { src_id: -o.id, kind: hood ? 6 : 5, flags: base | FLAG.osm, cc: near.cc, country: near.country, admin1: near.admin1, admin2: near.admin2, region_code: near.region_code,
      lat: o.lat, lng: o.lng, population: o.population, name: o.name, iata: null, fcode: `osm:${o.place}`, seat: false, incorporated: false, parent: null };
    all.push(x); placesGrid.add(x);
  }
  // the US Census: confirms a city (and makes it an incorporated place), adds an active one GeoNames and OpenStreetMap lack
  let mergedCensus = 0;
  for (const c of inp.census ?? []) {
    const rc = `US-${c.usps}`;
    if (!want(rc)) continue;
    const dup = nearestNamed(c.name, c.lat, c.lng, 15, [5]);
    if (dup) { dup.flags |= FLAG.census; dup.incorporated = dup.incorporated || c.active; mergedCensus++; continue; }
    if (!c.active) continue;
    const near = nearestAny(c.lat, c.lng, 'US');
    const x: Work = { src_id: -(1e13 + c.geoid), kind: 5, flags: base | FLAG.census, cc: 'US', country: 'US', admin1: c.usps, admin2: near?.admin1 === c.usps ? near.admin2 : '',
      region_code: rc, lat: c.lat, lng: c.lng, population: 0, name: c.name, iata: null, fcode: 'census', seat: false, incorporated: true, parent: null };
    all.push(x); placesGrid.add(x);
  }
  // cities inside a large city's radius become its neighbourhoods (never a seat, a large town or an incorporated place)
  const big = all.filter((x) => x.kind === 5 && x.population >= 100_000);
  const bigGrid = new Grid<Work>(0.5); for (const b of big) bigGrid.add(b);
  const hostOf = (x: Work, strict: boolean) => {
    let best: Work | null = null; let score = Infinity;
    for (const b of bigGrid.near(x.lat, x.lng, 1)) {
      if (b === x || b.country !== x.country) continue;
      const d = km(x.lat, x.lng, b.lat, b.lng); const r = cityRadius(b.population);
      if (strict ? d > r || x.population >= b.population * 0.1 : d > Math.max(r, 25)) continue;
      if (d / r < score) { score = d / r; best = b; }
    }
    return best;
  };
  for (const x of all) {
    if (x.kind !== 5 || x.seat || x.incorporated || x.population >= 100_000) continue;
    const h = hostOf(x, true);
    if (h) { x.kind = 6; x.parent = h.src_id; }
  }
  // parents
  const cities = all.filter((x) => x.kind === 5);
  const cityGrid = new Grid<Work>(0.5); for (const c of cities) cityGrid.add(c);
  const hoodGrid = new Grid<Work>(0.1); for (const h of all) if (h.kind === 6) hoodGrid.add(h);
  const nearestIn = (g: Grid<Work>, x: Work, maxKm: number, rings = 1) => {
    let best: Work | null = null; let bd = maxKm;
    for (const c of g.near(x.lat, x.lng, rings)) { if (c === x || c.country !== x.country) continue; const d = km(x.lat, x.lng, c.lat, c.lng); if (d <= bd) { bd = d; best = c; } }
    return best;
  };
  const provinceOf = (x: Work) => adm1.get(`${x.cc}.${x.admin1}`) ?? adm1.get(`${x.cc}.`);
  for (const x of all) {
    if (x.kind === 2) x.parent = countryIds[x.country] ?? null;
    else if (x.kind === 3) x.parent = (provinceOf(x)?.src_id ?? null);
    else if (x.kind === 5) x.parent = (adm2.get(`${x.cc}.${x.admin1}.${x.admin2}`) ?? provinceOf(x))?.src_id ?? null;
    else if (x.kind === 6 && x.parent === null) x.parent = (hostOf(x, false) ?? nearestIn(cityGrid, x, 25))?.src_id ?? provinceOf(x)?.src_id ?? null;
    else if (x.kind === 7) x.parent = (adm2.get(`${x.cc}.${x.admin1}.${x.admin2}`) ?? provinceOf(x))?.src_id ?? null;
    else if (x.kind === 8) x.parent = (nearestIn(hoodGrid, x, 1.5, 1) ?? nearestIn(cityGrid, x, 15, 1))?.src_id ?? null;
  }
  const kept = all.filter((x) => x.kind !== 8 || x.parent !== null);
  // slugs: the most important places first get the plainest name
  const byId = new Map(kept.map((x) => [x.src_id, x]));
  const short = (x: Work) => (x.region_code ? x.region_code.split('-')[1]!.toLowerCase() : x.country.toLowerCase());
  const used = new Set<string>(['canada', 'united-states', 'mexico', 'ontario', 'gta']);
  const order: Kind[] = [2, 5, 3, 6, 7, 8];
  const out: StagedPlace[] = [];
  for (const k of order) {
    const group = kept.filter((x) => x.kind === k).sort((a, b) => b.population - a.population || a.src_id - b.src_id);
    for (const x of group) {
      const parent = x.parent !== null ? byId.get(x.parent) : undefined;
      const region = adm2.get(`${x.cc}.${x.admin1}.${x.admin2}`);
      const tries = k === 2 ? [slugify(x.name), slugify(`${x.name} ${x.country}`)]
        : k === 5 ? [slugify(`${x.name} ${short(x)}`), slugify(`${x.name} ${region?.name ?? ''} ${short(x)}`)]
        : k === 3 ? [slugify(`${x.name}${/(county|region|district|municipality|division|parish|borough|municipio)/i.test(x.name) ? '' : ' region'} ${short(x)}`)]
        : k === 7 ? [slugify(`${x.iata ?? x.name} airport`), slugify(`${x.name} ${short(x)}`)]
        : [slugify(`${x.name} ${parent?.name ?? ''} ${short(x)}`), slugify(`${x.name} ${short(x)}`)];
      let slug = tries.find((t) => t && !used.has(t)) ?? '';
      if (!slug) slug = slugify(`${tries[0]} ${Math.abs(x.src_id) % 100000}`);
      used.add(slug);
      out.push({ src_id: x.src_id, kind: x.kind, flags: x.flags, region_code: x.region_code, country: x.country, lat: Math.round(x.lat * 1e5) / 1e5, lng: Math.round(x.lng * 1e5) / 1e5,
        population: x.population || null, parent_src_id: x.parent, slug, name: x.name, iata: x.iata });
    }
  }
  const counts: Record<string, Record<string, number>> = {};
  for (const p of out) { const c = (counts[p.country] ??= {}); c[KIND_NAME[p.kind]] = (c[KIND_NAME[p.kind]] ?? 0) + 1; }
  return { places: out, counts, merged: { osm: mergedOsm, census: mergedCensus } };
}

/** The staged places as CSV for COPY places_staging (src_id, kind, flags, region_code, country, lat, lng, population, parent_src_id, slug, name, iata). */
export function toCsv(rows: StagedPlace[]): string {
  const q = (v: unknown) => (v === null || v === undefined ? '' : /[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  return rows.map((r) => [r.src_id, r.kind, r.flags, r.region_code, r.country, r.lat, r.lng, r.population, r.parent_src_id, r.slug, r.name, r.iata].map(q).join(',')).join('\n') + (rows.length ? '\n' : '');
}
export const CSV_COLUMNS = 'src_id, kind, flags, region_code, country, lat, lng, population, parent_src_id, slug, name, iata';
