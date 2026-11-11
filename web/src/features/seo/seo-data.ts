// The seo-data workflow's pure parts (release 35, part M; web/scripts/seo-data.mjs, .github/workflows/seo-data.yml):
// reading the transit agencies' GTFS stops, OpenStreetMap hotels, fueleconomy.gov and NHTSA answers and a curated
// spec or cost CSV into the rows public.server_seo_data_load takes (migration 1100). Every row carries its source URL
// and the time it was fetched; a value that is missing is left out, never filled in. Relative imports only.

export interface PoiRow { kind: 'go_station' | 'rail_station' | 'subway_station' | 'bus_stop' | 'hotel' | 'parking_lot' | 'street_parking'; agency: string | null; ref: string; name: string; lat: number; lng: number;
  source: 'gtfs' | 'osm'; source_url: string; licence: string; attribution: string; fetched_at: string; detail?: Record<string, string | number> }
export interface SpecRow { make: string; model: string; year: number; trim: string; field: string; value: string; code?: string | null; source: string; source_url: string; fetched_at: string }

/** A CSV file (RFC 4180: quoted fields, doubled quotes, CRLF), as objects keyed by the header. */
export function parseCsv(text: string): Array<Record<string, string>> {
  const rows: string[][] = [];
  let row: string[] = [], cell = '', q = false;
  const s = text.replace(/^﻿/, '');
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]!;
    if (q) {
      if (ch === '"') { if (s[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += ch;
    } else if (ch === '"') q = true;
    else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && s[i + 1] === '\n') i++; row.push(cell); cell = ''; if (row.some((c) => c !== '')) rows.push(row); row = []; }
    else cell += ch;
  }
  if (cell !== '' || row.length) { row.push(cell); if (row.some((c) => c !== '')) rows.push(row); }
  const head = (rows.shift() ?? []).map((h) => h.trim());
  return rows.map((r) => Object.fromEntries(head.map((h, i) => [h, (r[i] ?? '').trim()])));
}

/** The GTFS feeds the workflow reads (official agency feeds; the URL is checked on each run and a feed that fails is skipped). */
export interface Feed { agency: string; url: string; licence: string; page: string }

/** A GTFS stop as a place page shows it: GO stations, subway and LRT stations, bus stops. Platforms and entrances
 *  (location_type 2 to 4) and stops inside a station (a parent_station) are left out. */
export function gtfsStops(feed: Feed, stops: Array<Record<string, string>>, fetchedAt: string): PoiRow[] {
  const out: PoiRow[] = [];
  for (const s of stops) {
    const lt = s.location_type || '0';
    if (lt !== '0' && lt !== '1') continue;
    if (s.parent_station && lt === '0') continue;
    const lat = Number(s.stop_lat), lng = Number(s.stop_lon), name = (s.stop_name ?? '').trim();
    if (!name || !Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) continue;
    const station = lt === '1' || /\bstation\b/i.test(name);
    const kind: PoiRow['kind'] = feed.agency === 'GO Transit' ? (station || /\bGO$/.test(name) ? 'go_station' : 'bus_stop')
      : station ? (feed.agency === 'TTC' ? 'subway_station' : 'rail_station') : 'bus_stop';
    out.push({ kind, agency: feed.agency, ref: (s.stop_id || '').slice(0, 80), name: name.slice(0, 160), lat: +lat.toFixed(6), lng: +lng.toFixed(6), source: 'gtfs',
      source_url: feed.page, licence: feed.licence, attribution: `Stops: ${feed.agency} GTFS (${feed.licence})`, fetched_at: fetchedAt });
  }
  return out.filter((r) => r.ref);
}

/** OpenStreetMap hotels from an Overpass answer: named ones only (a business, never a person's home). */
export function osmHotels(answer: { elements?: Array<{ type: string; id: number; lat?: number; lon?: number; center?: { lat: number; lon: number }; tags?: Record<string, string> }> }, fetchedAt: string): PoiRow[] {
  const out: PoiRow[] = [];
  for (const e of answer.elements ?? []) {
    const name = e.tags?.name?.trim();
    const lat = e.lat ?? e.center?.lat, lng = e.lon ?? e.center?.lon;
    if (!name || lat === undefined || lng === undefined || !['hotel', 'motel'].includes(e.tags?.tourism ?? '')) continue;
    out.push({ kind: 'hotel', agency: null, ref: `${e.type}/${e.id}`, name: name.slice(0, 160), lat: +lat.toFixed(6), lng: +lng.toFixed(6), source: 'osm',
      source_url: `https://www.openstreetmap.org/${e.type}/${e.id}`, licence: 'ODbL 1.0', attribution: 'Hotels: © OpenStreetMap contributors (ODbL)', fetched_at: fetchedAt });
  }
  return out;
}

/** US miles per gallon to litres per 100 km, one decimal. */
export const mpgToL100 = (mpg: number) => Math.round((235.214583 / mpg) * 10) / 10;

/** A fueleconomy.gov vehicle record (https://www.fueleconomy.gov/ws/rest/vehicle/<id>) as spec rows of its model year. */
export function fuelEconomyRows(v: Record<string, string | number | null | undefined>, t: { make: string; model: string; year: number }, fetchedAt: string): SpecRow[] {
  const url = `https://www.fueleconomy.gov/feg/PowerSearch.do?action=noform&path=1&year1=${t.year}&year2=${t.year}&make=${encodeURIComponent(t.make)}&baseModel=${encodeURIComponent(t.model)}`;
  const trim = String(v.trany ?? '') && String(v.model ?? '') !== t.model ? String(v.model ?? '').trim() : '';
  const rows: SpecRow[] = [];
  const add = (field: string, value: string | null) => { if (value) rows.push({ make: t.make, model: t.model, year: t.year, trim, field, value, source: 'fueleconomy_gov', source_url: url, fetched_at: fetchedAt }); };
  const num = (x: unknown) => (x === null || x === undefined || x === '' || Number(x) <= 0 ? null : Number(x));
  const ev = /electric/i.test(String(v.fuelType ?? '')) && !/gasoline|regular|premium/i.test(String(v.fuelType ?? ''));
  if (!ev) {
    const c = num(v.city08), h = num(v.highway08), m = num(v.comb08);
    add('fuel_city_l100', c ? String(mpgToL100(c)) : null); add('fuel_highway_l100', h ? String(mpgToL100(h)) : null); add('fuel_combined_l100', m ? String(mpgToL100(m)) : null);
  } else {
    const kwh = num(v.combE); add('kwh100_combined', kwh ? String(Math.round((kwh / 1.609344) * 10) / 10) : null);
    const r = num(v.range); add('range_km', r ? String(Math.round(r * 1.609344)) : null);
  }
  add('fuel_type', v.fuelType ? String(v.fuelType) : null);
  add('drivetrain', v.drive ? String(v.drive) : null);
  add('transmission', v.trany ? String(v.trany) : null);
  const displ = num(v.displ), cyl = num(v.cylinders);
  add('engine', displ && cyl ? `${displ} L, ${cyl} cylinders` : null);
  return rows;
}

/** NHTSA's recalls for a model year (api.nhtsa.gov/recalls/recallsByVehicle) as one row: the count. */
export function recallRow(answer: { Count?: number; results?: unknown[] }, t: { make: string; model: string; year: number }, fetchedAt: string): SpecRow | null {
  const n = typeof answer.Count === 'number' ? answer.Count : Array.isArray(answer.results) ? answer.results.length : null;
  if (n === null) return null;
  return { make: t.make, model: t.model, year: t.year, trim: '', field: 'recalls', value: String(n), source: 'nhtsa_recalls',
    source_url: `https://www.nhtsa.gov/vehicle/${t.year}/${encodeURIComponent(t.make.toUpperCase())}/${encodeURIComponent(t.model.toUpperCase())}`, fetched_at: fetchedAt };
}

/** NHTSA's 5-star ratings (api.nhtsa.gov/SafetyRatings/VehicleId/<id>) as rows; "Not Rated" is left out. */
export function ratingRows(r: Record<string, string | number | undefined>, t: { make: string; model: string; year: number }, fetchedAt: string): SpecRow[] {
  const url = `https://www.nhtsa.gov/vehicle/${t.year}/${encodeURIComponent(t.make.toUpperCase())}/${encodeURIComponent(t.model.toUpperCase())}`;
  const out: SpecRow[] = [];
  for (const [k, field] of [['OverallRating', 'safety_overall'], ['OverallFrontCrashRating', 'safety_frontal'], ['OverallSideCrashRating', 'safety_side'], ['RolloverRating', 'safety_rollover']] as const) {
    const v = String(r[k] ?? '');
    if (/^[1-5]$/.test(v)) out.push({ make: t.make, model: t.model, year: t.year, trim: '', field, value: v, source: 'nhtsa_ratings', source_url: url, fetched_at: fetchedAt });
  }
  return out;
}

/** The fields a curated CSV may carry (2001 added prices, production, plants, markets, problems, equipment, charging, body). */
export const CURATED_FIELDS = new Set(['tire_size', 'rim_size', 'fuel_city_l100', 'fuel_highway_l100', 'fuel_combined_l100', 'fuel_type', 'tank_l', 'kwh100_combined', 'range_km', 'features', 'paint_colour', 'hp',
  'torque_nm', 'zero_100_s', 'top_speed_kmh', 'drivetrain', 'transmission', 'curb_kg', 'towing_kg', 'seats', 'cargo_l', 'length_mm', 'width_mm', 'height_mm', 'wheelbase_mm', 'engine',
  'msrp_usd', 'msrp_cad', 'production_start', 'production_end', 'assembly_plant', 'markets', 'production_total', 'na_sales', 'common_problem', 'sunroof', 'headlights', 'carplay',
  'android_auto', 'passengers', 'suitcases', 'battery_kwh', 'charge_dc_kw', 'charge_ac_kw', 'charge_connector', 'body_style', 'doors', 'ground_clearance_mm', 'turning_circle_m', 'warranty']);
const FIELDS = CURATED_FIELDS;
/** A curated spec CSV (OEM spec pages, open datasets: make,model,year,trim,field,value,code,source,source_url) as rows;
 *  a row with no https source URL, an unknown field or no value is refused (returned in rejected). */
export function curatedSpecRows(rows: Array<Record<string, string>>, fetchedAt: string): { rows: SpecRow[]; rejected: number } {
  const out: SpecRow[] = [];
  let rejected = 0;
  for (const r of rows) {
    const year = Number(r.year);
    const source = r.source === 'oem' || r.source === 'open_dataset' ? r.source : null;
    if (!r.make || !r.model || !Number.isInteger(year) || !FIELDS.has(r.field ?? '') || !r.value || !source || !/^https:\/\//.test(r.source_url ?? '')) { rejected++; continue; }
    out.push({ make: r.make, model: r.model, year, trim: r.trim ?? '', field: r.field!, value: r.value, code: r.code || null, source, source_url: r.source_url!, fetched_at: r.fetched_at || fetchedAt });
  }
  return { rows: out, rejected };
}

/** Rows in chunks for the loader (it takes 50,000 at most; smaller keeps each SQL file small). */
export function chunks<T>(xs: T[], n = 2000): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

// ---------------------------------------------------------------- release 36 (migration 2001): more sources
type Target = { make: string; model: string; year: number };
const nhtsaPage = (t: Target) => `https://www.nhtsa.gov/vehicle/${t.year}/${encodeURIComponent(t.make.toUpperCase())}/${encodeURIComponent(t.model.toUpperCase())}`;
const same = (a: string, b: string) => a.toLowerCase().replace(/[^a-z0-9]/g, '') === b.toLowerCase().replace(/[^a-z0-9]/g, '');

/** NHTSA's recalls of a model year as one row per campaign (code: the campaign number, value: the component). */
export function recallItemRows(answer: { results?: Array<Record<string, unknown>> }, t: Target, fetchedAt: string): SpecRow[] {
  const out: SpecRow[] = [];
  for (const r of answer.results ?? []) {
    const code = String(r.NHTSACampaignNumber ?? '').trim(), comp = String(r.Component ?? '').trim();
    if (!code || !comp) continue;
    out.push({ make: t.make, model: t.model, year: t.year, trim: '', field: 'recall_item', value: titleCase(comp.split(':')[0]!).slice(0, 120), code: code.slice(0, 40),
      source: 'nhtsa_recalls', source_url: nhtsaPage(t), fetched_at: fetchedAt });
  }
  return out;
}
const titleCase = (x: string) => x.toLowerCase().replace(/(^|[\s/,(-])([a-z])/g, (_, a: string, b: string) => a + b.toUpperCase()).trim();

/** NHTSA's owner complaints of a model year: the components with the most complaints (at least `min`), as the common
 *  problems, each "Electrical System (42 complaints to NHTSA)". */
export function complaintRows(answer: { results?: Array<{ components?: string }> }, t: Target, fetchedAt: string, min = 5, top = 4): SpecRow[] {
  const n = new Map<string, number>();
  for (const r of answer.results ?? []) for (const c of String(r.components ?? '').split(',').map((x) => x.split(':')[0]!.trim()).filter(Boolean)) n.set(c, (n.get(c) ?? 0) + 1);
  return [...n].filter(([, k]) => k >= min).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, top)
    .map(([c, k]) => ({ make: t.make, model: t.model, year: t.year, trim: '', field: 'common_problem', value: `${titleCase(c)} (${k} complaints to NHTSA)`, source: 'nhtsa_complaints', source_url: nhtsaPage(t), fetched_at: fetchedAt }));
}

/** vPIC's Canadian vehicle specifications (GetCanadianVehicleSpecifications, units=Metric: lengths in cm, weight in kg)
 *  for the target's model: length, width, height, wheelbase in mm and the curb weight. The first body of the model. */
export function vpicCanadaRows(answer: { Results?: Array<{ Specs?: Array<{ Name: string; Value: unknown }> }> }, t: Target, fetchedAt: string): SpecRow[] {
  const url = `https://vpic.nhtsa.dot.gov/api/vehicles/GetCanadianVehicleSpecifications/?Year=${t.year}&Make=${encodeURIComponent(t.make)}&Model=${encodeURIComponent(t.model)}&units=Metric&format=json`;
  for (const res of answer.Results ?? []) {
    const rec = Object.fromEntries((res.Specs ?? []).map((x) => [x.Name, String(x.Value ?? '').trim()]));
    if (!rec.Model || !same(rec.Model, t.model)) continue;
    const rows: SpecRow[] = [];
    const add = (field: string, v: string | undefined, k: number) => { const x = Number(v); if (v && Number.isFinite(x) && x > 0) rows.push({ make: t.make, model: t.model, year: t.year, trim: '', field, value: String(Math.round(x * k)), source: 'nhtsa_vpic', source_url: url, fetched_at: fetchedAt }); };
    add('length_mm', rec.OL, 10); add('width_mm', rec.OW, 10); add('height_mm', rec.OH, 10); add('wheelbase_mm', rec.WB, 10); add('curb_kg', rec.CW, 1);
    if (rows.length) return rows;
  }
  return [];
}

/** Transport Canada's Motor Vehicle Safety Recalls Database (data.tc.gc.ca, Open Government Licence - Canada): the
 *  recall campaigns of a model year as a count (tc_recalls) and one row per campaign (recall_item, code: TC's number). */
export function tcRecallRows(answer: unknown, t: Target, fetchedAt: string): SpecRow[] {
  const url = 'https://tc.canada.ca/en/road-transportation/motor-vehicle-safety/motor-vehicle-safety-recalls-database';
  const recs: Array<Record<string, string>> = [];
  const flat = (x: unknown): void => {
    if (Array.isArray(x)) {
      if (x.length && x.every((y) => y && typeof y === 'object' && 'Name' in (y as object))) {
        recs.push(Object.fromEntries((x as Array<{ Name: string; Value: unknown }>).map((y) => [String(y.Name).toLowerCase(), String((y.Value as { Literal?: unknown })?.Literal ?? y.Value ?? '')])));
      } else x.forEach(flat);
    } else if (x && typeof x === 'object') Object.values(x).forEach(flat);
  };
  flat(answer);
  const seen = new Map<string, string>();
  for (const r of recs) {
    const no = (r['recall number'] ?? r['recallnumber'] ?? r['recall_number'] ?? '').trim();
    if (no && !seen.has(no)) seen.set(no, (r['system type'] ?? r['category'] ?? r['component'] ?? '').trim());
  }
  if (!seen.size && !recs.length && !Array.isArray((answer as { ResultSet?: unknown })?.ResultSet)) return [];
  const rows: SpecRow[] = [{ make: t.make, model: t.model, year: t.year, trim: '', field: 'tc_recalls', value: String(seen.size), source: 'transport_canada', source_url: url, fetched_at: fetchedAt }];
  for (const [no, comp] of seen) if (comp) rows.push({ make: t.make, model: t.model, year: t.year, trim: '', field: 'recall_item', value: titleCase(comp).slice(0, 120), code: `TC ${no}`.slice(0, 40), source: 'transport_canada', source_url: url, fetched_at: fetchedAt });
  return rows;
}

/** The Wikidata query of one make's car models: production start and end, assembly plants, units produced (CC0). */
export const wikidataMakeQuery = (make: string) => `SELECT ?model ?modelLabel ?start ?end ?plantLabel ?total WHERE {
  ?model wdt:P31/wdt:P279* wd:Q3231690 .
  { ?model wdt:P1716 ?b } UNION { ?model wdt:P176 ?b }
  ?b rdfs:label "${make.replace(/["\\]/g, '')}"@en .
  OPTIONAL { { ?model wdt:P571 ?start } UNION { ?model wdt:P2031 ?start } }
  OPTIONAL { { ?model wdt:P2669 ?end } UNION { ?model wdt:P2032 ?end } UNION { ?model wdt:P576 ?end } }
  OPTIONAL { ?model wdt:P1071 ?plant }
  OPTIONAL { ?model wdt:P1092 ?total }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
} LIMIT 2000`;

/** Wikidata's answer for one make, as the rows of each target of that make whose model it names (the model's label
 *  equal to the target's, or the target's model with a generation suffix). Production years are the model's. */
export function wikidataRows(answer: { results?: { bindings?: Array<Record<string, { value: string }>> } }, targets: Target[], fetchedAt: string): SpecRow[] {
  const out: SpecRow[] = [];
  const byModel = new Map<string, { id: string; start?: number; end?: number; plants: Set<string>; total?: number }>();
  for (const b of answer.results?.bindings ?? []) {
    const label = b.modelLabel?.value ?? '', id = (b.model?.value ?? '').replace(/^.*\//, '');
    if (!label || !/^Q\d+$/.test(id)) continue;
    const m = byModel.get(label) ?? { id, plants: new Set<string>() };
    const yr = (v?: { value: string }) => (v ? Number(v.value.slice(0, 4)) : undefined);
    const s = yr(b.start), e = yr(b.end);
    if (s && (!m.start || s < m.start)) m.start = s;
    if (e && (!m.end || e > m.end)) m.end = e;
    if (b.plantLabel?.value && !/^Q\d+$/.test(b.plantLabel.value)) m.plants.add(b.plantLabel.value);
    if (b.total?.value && Number(b.total.value) > 0) m.total = Math.round(Number(b.total.value));
    byModel.set(label, m);
  }
  for (const t of targets) {
    const hit = [...byModel].find(([label]) => same(label, t.model) || same(label, `${t.make} ${t.model}`));
    if (!hit) continue;
    const [, m] = hit;
    if (m.start && m.start > t.year) continue;
    const url = `https://www.wikidata.org/wiki/${m.id}`;
    const add = (field: string, value: string) => out.push({ make: t.make, model: t.model, year: t.year, trim: '', field, value, source: 'wikidata', source_url: url, fetched_at: fetchedAt });
    if (m.start) add('production_start', String(m.start));
    if (m.end && m.end >= t.year) add('production_end', String(m.end));
    for (const p of [...m.plants].slice(0, 6)) add('assembly_plant', p.slice(0, 160));
    if (m.total) add('production_total', String(m.total));
  }
  return out;
}

/** OpenStreetMap parking from an Overpass answer: lots and garages (amenity=parking) open to the public, named or with
 *  a capacity, and streets with parking lanes (parking:lane:* or parking:both|left|right), each with what OSM says. */
export function osmParking(answer: { elements?: Array<{ type: string; id: number; lat?: number; lon?: number; center?: { lat: number; lon: number }; tags?: Record<string, string> }> }, fetchedAt: string): PoiRow[] {
  const out: PoiRow[] = [];
  const seenStreet = new Set<string>();
  for (const e of answer.elements ?? []) {
    const g = e.tags ?? {};
    const lat = e.lat ?? e.center?.lat, lng = e.lon ?? e.center?.lon;
    if (lat === undefined || lng === undefined) continue;
    const base = { agency: null, ref: `${e.type}/${e.id}`, lat: +lat.toFixed(6), lng: +lng.toFixed(6), source: 'osm' as const, source_url: `https://www.openstreetmap.org/${e.type}/${e.id}`,
      licence: 'ODbL 1.0', attribution: 'Parking: © OpenStreetMap contributors (ODbL)', fetched_at: fetchedAt };
    if (g.amenity === 'parking') {
      if (['private', 'no', 'customers', 'permit', 'delivery'].includes(g.access ?? '')) continue;
      const cap = Number(g.capacity);
      if (!g.name && !(cap >= 20)) continue;
      const kind = g.parking === 'multi-storey' ? 'Parking garage' : g.parking === 'underground' ? 'Underground parking' : 'Parking lot';
      const detail: Record<string, string | number> = {};
      if (g.parking) detail.parking = g.parking;
      if (g.fee) detail.fee = g.fee;
      if (cap > 0) detail.capacity = Math.round(cap);
      if (g.maxstay) detail.maxstay = g.maxstay.slice(0, 40);
      if (g.operator) detail.operator = g.operator.slice(0, 80);
      out.push({ ...base, kind: 'parking_lot', name: (g.name ?? `${kind}${g.operator ? `, ${g.operator}` : ''}`).slice(0, 160), detail });
    } else if (g.name && g.highway) {
      const sides: string[] = [];
      for (const side of ['both', 'left', 'right'] as const) {
        const v = g[`parking:${side}`] ?? g[`parking:lane:${side}`];
        if (v && !['no', 'none', 'no_parking', 'no_stopping', 'separate'].includes(v)) sides.push(side);
      }
      if (!sides.length) continue;
      const key = `${g.name}|${Math.round(lat * 200)}|${Math.round(lng * 200)}`;
      if (seenStreet.has(key)) continue;
      seenStreet.add(key);
      const detail: Record<string, string | number> = { parking: 'street', sides: sides.join(',') };
      const fee = g['parking:both:fee'] ?? g['parking:right:fee'] ?? g['parking:left:fee'] ?? g['parking:condition:both'];
      if (fee) detail.fee = fee.slice(0, 40);
      const stay = g['parking:both:maxstay'] ?? g['parking:right:maxstay'] ?? g['parking:left:maxstay'] ?? g['parking:condition:both:maxstay'];
      if (stay) detail.maxstay = stay.slice(0, 40);
      out.push({ ...base, kind: 'street_parking', name: g.name.slice(0, 160), detail });
    }
  }
  return out;
}
