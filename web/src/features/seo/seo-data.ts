// The seo-data workflow's pure parts (release 35, part M; web/scripts/seo-data.mjs, .github/workflows/seo-data.yml):
// reading the transit agencies' GTFS stops, OpenStreetMap hotels, fueleconomy.gov and NHTSA answers and a curated
// spec or cost CSV into the rows public.server_seo_data_load takes (migration 1100). Every row carries its source URL
// and the time it was fetched; a value that is missing is left out, never filled in. Relative imports only.

export interface PoiRow { kind: 'go_station' | 'rail_station' | 'subway_station' | 'bus_stop' | 'hotel'; agency: string | null; ref: string; name: string; lat: number; lng: number;
  source: 'gtfs' | 'osm'; source_url: string; licence: string; attribution: string; fetched_at: string }
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

const FIELDS = new Set(['tire_size', 'rim_size', 'fuel_city_l100', 'fuel_highway_l100', 'fuel_combined_l100', 'fuel_type', 'tank_l', 'kwh100_combined', 'range_km', 'features', 'paint_colour', 'hp',
  'torque_nm', 'zero_100_s', 'top_speed_kmh', 'drivetrain', 'transmission', 'curb_kg', 'towing_kg', 'seats', 'cargo_l', 'length_mm', 'width_mm', 'height_mm', 'wheelbase_mm', 'engine']);
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
