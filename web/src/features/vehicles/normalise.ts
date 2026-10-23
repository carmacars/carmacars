// The vehicle catalog import (migration 0097, web/scripts/catalog/import.mjs): the US EPA fueleconomy.gov vehicles file
// (public domain) read into makes, models, model years and their powertrains; NHTSA vPIC model names (public domain)
// for coverage and names; the Canadian trims from the CarmaCars trim list (web/scripts/catalog/canada-trims.txt).
// Pure functions: no imports beyond ./units.ts, nothing read or written here.
import { kwh100miTo100km, miToKm, modelKey, mpgToL100, slugify, trimSlug } from './units.ts';

/** Every make of the EPA file is in the catalog (the owner, October 22, 2026: every make, exotics included, every year).
 *  The name shown: this list where the EPA spelling differs in case or carries a company suffix, else EPA's own
 *  spelling less "Inc.", "LLC", "Ltd" and the like. */
export const MAKE_NAMES: Record<string, string> = {
  'FIAT': 'Fiat', 'Mini': 'MINI', 'MINI': 'MINI', 'smart': 'smart', 'McLaren Automotive': 'McLaren', 'Roush Performance': 'Roush',
  'Saleen Performance': 'Saleen', 'TVR Engineering Ltd': 'TVR', 'Panoz Auto-Development': 'Panoz', 'CODA Automotive': 'CODA',
  'Mobility Ventures LLC': 'Mobility Ventures', 'Shelby American Inc': 'Shelby', 'Ruf Automobile Gmbh': 'RUF', 'Pagani': 'Pagani',
  'Bugatti': 'Bugatti', 'Koenigsegg': 'Koenigsegg', 'Rolls-Royce': 'Rolls-Royce', 'Aston Martin': 'Aston Martin', 'Lotus': 'Lotus',
  'Grumman Olson': 'Grumman Olson', 'Lambda Control Systems': 'Lambda Control Systems'
};
/** The name a make is shown with, from EPA's spelling (or null for an empty one). */
export function makeName(raw: string): string | null {
  const s = raw.replace(/\s+/g, ' ').trim();
  if (!s) return null;
  if (MAKE_NAMES[s]) return MAKE_NAMES[s]!;
  const plain = s.replace(/,?\s+(inc\.?|llc|ltd\.?|limited|corp\.?|corporation|co\.?|gmbh|s\.?p\.?a\.?|ag|plc)$/i, '').trim();
  return plain || s;
}
/** Words in an EPA model name that say the drive, the body or the cab, not the model or the trim. */
const GENERIC = new Set(['2wd', '4wd', 'awd', 'fwd', 'rwd', '4x4', '4x2', '4matic', '4matic+', 'xdrive', 'sdrive', 'quattro', '4motion', 'sh-awd', 'all4', 'e-four',
  'pickup', 'cab', 'chassis', 'sedan', 'coupe', 'convertible', 'cabriolet', 'roadster', 'hatchback', 'wagon', 'van', 'cargo', 'passenger', 'suv', 'crossover',
  'ffv', 'doors', '2dr', '4dr', '5dr', '3dr', 'door', 'shawd', 'efour']);

export type Variant = {
  id: number; epa_model: string; special: string[]; displ: number | null; cyl: number | null; turbo: boolean; super: boolean;
  drive: string | null; trans: string | null; fuel: string; vclass: string | null;
  l100_city: number | null; l100_hwy: number | null; l100_comb: number | null; kwh100: number | null; ev_range_km: number | null; co2_g_km: number | null;
  /** EPA's own figures as published: MPG (MPGe for an EV) in US gallons, the annual fuel cost in US dollars (15,000 miles,
   *  EPA's prices), the hours to charge at 240 V, the luggage volume in cubic feet, the battery in kWh when EPA names it */
  mpg_city?: number | null; mpg_hwy?: number | null; mpg_comb?: number | null; fuel_cost_usd?: number | null; charge240_h?: number | null;
  luggage_cuft?: number | null; battery_kwh?: number | null;
  /** where the figures come from when it is not EPA: 'nrcan' (Natural Resources Canada's Fuel Consumption Ratings, 0115) */
  src?: 'nrcan';
};
/** A body's Canadian dimensions and curb weight, as NHTSA vPIC's Canadian specifications give them (cm, kg). */
export type Dim = { body: string; length_cm: number | null; width_cm: number | null; height_cm: number | null; wheelbase_cm: number | null; curb_kg: number | null };
export type Recall = { campaign: string; date: string | null; component: string | null; summary: string | null };
export type Complaints = { total: number; components: Array<{ component: string; n: number }> };
export type YearRow = { make: string; model: string; year: number; vclass: string | null; variants: Variant[]; sources: string[]; dims?: Dim[]; recalls?: Recall[]; complaints?: Complaints };
export type ModelRow = { make: string; slug: string; name: string; key: string; aliases: string[]; vclass: string | null; sources: string[] };
export type MakeRow = { slug: string; name: string };
export type TrimLine = { make: string; model: string; from: number; to: number; trims: string[] };
export type Catalog = { makes: MakeRow[]; models: ModelRow[]; years: YearRow[]; trim_lines: TrimLine[]; popular: Array<{ make: string; model: string; sort: number }> };

/** RFC 4180 CSV (quoted fields, doubled quotes, CRLF), first row the header. */
export function parseCsv(text: string): Array<Record<string, string>> {
  const rows = csvRows(text);
  const head = (rows.shift() ?? []).map((h) => h.trim());
  return rows.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])));
}
/** RFC 4180 CSV as rows of cells (a leading byte-order mark dropped). */
export function csvRows(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], field = '', q = false;
  for (let i = text.charCodeAt(0) === 0xfeff ? 1 : 0; i < text.length; i++) {
    const c = text[i]!;
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(field); field = ''; if (row.length > 1 || row[0] !== '') rows.push(row); row = []; }
    else field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows;
}

const num = (s: string | undefined) => { const n = Number(String(s ?? '').trim()); return Number.isFinite(n) && String(s ?? '').trim() !== '' ? n : null; };
/** a header looked up without caring about case (the EPA file has said baseModel and basemodel) */
const pick = (r: Record<string, string>, k: string) => { if (k in r) return r[k]; const lk = k.toLowerCase(); for (const h of Object.keys(r)) if (h.toLowerCase() === lk) return r[h]; return undefined; };

/** The fuel of an EPA row in the site's words (vehicles.fuel), with premium gas kept apart for the price. */
export function fuelOf(r: Record<string, string>): string {
  const atv = String(pick(r, 'atvType') ?? '').toLowerCase();
  const f = String(pick(r, 'fuelType') ?? '').toLowerCase();
  if (atv === 'ev' || f === 'electricity') return 'electric';
  if (atv === 'plug-in hybrid' || /or electricity/.test(f)) return 'plug_in_hybrid';
  if (atv === 'hybrid') return 'hybrid';
  if (atv === 'diesel' || /diesel/.test(f)) return 'diesel';
  if (/premium/.test(f)) return 'premium';
  return 'gasoline';
}

/** The words of an EPA model name beyond its base model, less drive and body words, each as one compact token:
 *  "Jetta GLI" gives ["gli"]. Words EPA joins with "/" are alternatives ("Camry Hybrid SE/XLE/XSE" gives
 *  ["hybrid", "se|xle|xse"]): a trim names one of them. */
export function specialTokens(epaModel: string, baseModel: string): string[] {
  const words = epaModel.trim().split(/\s+/).filter(Boolean);
  const want = modelKey(baseModel);
  let rest = words;
  let acc = '';
  for (let i = 0; i < words.length && want; i++) {
    acc += modelKey(words[i]);
    if (acc === want) { rest = words.slice(i + 1); break; }
    if (!want.startsWith(acc)) break;
  }
  return rest.map((w) => w.split('/').map((x) => modelKey(x)).filter((x) => x && !GENERIC.has(x) && !/^\d{1,2}(wd|dr)$/.test(x)))
    .filter((alts) => alts.length).map((alts) => [...new Set(alts)].join('|'));
}

/** One EPA row as a powertrain, or null when it is outside the years or makes the site covers. */
export function variantOf(r: Record<string, string>, years: [number, number]): { make: string; makeName: string; base: string; year: number; v: Variant } | null {
  const year = num(pick(r, 'year'));
  const name = makeName(String(pick(r, 'make') ?? ''));
  if (!year || year < years[0] || year > years[1] || !name) return null;
  const epaModel = String(pick(r, 'model') ?? '').trim();
  const base = String(pick(r, 'baseModel') ?? '').trim() || epaModel;
  if (!epaModel) return null;
  const fuel = fuelOf(r);
  const ev = fuel === 'electric';
  const tc = String(pick(r, 'tCharger') ?? '').trim(), sc = String(pick(r, 'sCharger') ?? '').trim();
  const rng = num(pick(r, 'range')) || (fuel === 'plug_in_hybrid' ? num(String(pick(r, 'rangeA') ?? '').split('/')[0]) : null);
  const co2 = num(pick(r, 'co2TailpipeGpm'));
  return {
    make: slugify(name), makeName: name, base, year,
    v: {
      id: num(pick(r, 'id')) ?? 0, epa_model: epaModel, special: specialTokens(epaModel, base),
      displ: ev ? null : num(pick(r, 'displ')), cyl: ev ? null : num(pick(r, 'cylinders')), turbo: tc === 'T' || tc === 'TRUE' || tc === '1', super: sc === 'S',
      drive: String(pick(r, 'drive') ?? '').trim() || null, trans: String(pick(r, 'trany') ?? '').trim() || null, fuel,
      vclass: String(pick(r, 'VClass') ?? '').trim() || null,
      l100_city: ev ? null : mpgToL100(num(pick(r, 'city08U')) || num(pick(r, 'city08'))),
      l100_hwy: ev ? null : mpgToL100(num(pick(r, 'highway08U')) || num(pick(r, 'highway08'))),
      l100_comb: ev ? null : mpgToL100(num(pick(r, 'comb08U')) || num(pick(r, 'comb08'))),
      kwh100: ev ? kwh100miTo100km(num(pick(r, 'combE'))) : null,
      ev_range_km: ev || fuel === 'plug_in_hybrid' ? miToKm(rng) : null,
      co2_g_km: co2 && co2 > 0 ? Math.round(co2 / 1.609344) : (ev ? 0 : null),
      mpg_city: pos(num(pick(r, 'city08'))), mpg_hwy: pos(num(pick(r, 'highway08'))), mpg_comb: pos(num(pick(r, 'comb08'))),
      fuel_cost_usd: pos(num(pick(r, 'fuelCost08'))), charge240_h: ev || fuel === 'plug_in_hybrid' ? pos(num(pick(r, 'charge240'))) : null,
      luggage_cuft: pos(Math.max(num(pick(r, 'lv2')) ?? 0, num(pick(r, 'lv4')) ?? 0, num(pick(r, 'hlv')) ?? 0)),
      battery_kwh: ev || fuel === 'plug_in_hybrid' ? pos(num(/(\d+(?:\.\d+)?)\s*kW[- ]?hr?\b/i.exec(String(pick(r, 'evMotor') ?? ''))?.[1])) : null
    }
  };
}
const pos = (n: number | null) => (n !== null && n > 0 ? n : null);

/** The size class without the drive ("Small Sport Utility Vehicle 4WD" is "Small Sport Utility Vehicle"). */
export const classOf = (s: string | null) => (s ? s.replace(/\s+[24]WD$/i, '').replace(/\s*-\s*[24]WD$/i, '').trim() : null);
const mode = (xs: Array<string | null>) => { const n = new Map<string, number>(); for (const x of xs) if (x) n.set(x, (n.get(x) ?? 0) + 1); return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0]?.[0] ?? null; };

/** vPIC's names for a make's models (by year): used for the shown name ("F-150" over EPA's "F150") and for coverage. */
export type VpicNames = Map<string, Map<number, string[]>>; // make slug -> year -> model names

/** The EPA rows and vPIC names as the catalog. vPIC adds years only to models EPA knows or the trim list names. */
export function buildCatalog(rows: Array<Record<string, string>>, opts: { years: [number, number]; vpic?: VpicNames; trimLines?: TrimLine[]; popular?: Array<{ make: string; model: string }>;
  extra?: ExtraSource[] }): Catalog {
  const makes = new Map<string, string>();
  const models = new Map<string, { make: string; name: string; key: string; aliases: Set<string>; vclass: Array<string | null>; sources: Set<string> }>();
  const years = new Map<string, YearRow>();
  for (const r of rows) {
    const x = variantOf(r, opts.years);
    if (!x) continue;
    makes.set(x.make, x.makeName);
    const key = modelKey(x.base);
    if (!key) continue;
    const mk = `${x.make}|${key}`;
    let m = models.get(mk);
    if (!m) { m = { make: x.make, name: x.base, key, aliases: new Set(), vclass: [], sources: new Set(['epa']) }; models.set(mk, m); }
    m.vclass.push(classOf(x.v.vclass));
    // the EPA model less drive and body words ("C300 4matic" is "c300", "330i xDrive Sedan" is "330i"): how a car's own model finds this one
    const plain = slugify(x.v.epa_model).split('-').filter((t) => t && !GENERIC.has(t)).join('');
    if (plain && plain !== key) m.aliases.add(plain);
    const yk = `${mk}|${x.year}`;
    let y = years.get(yk);
    if (!y) { y = { make: x.make, model: key, year: x.year, vclass: null, variants: [], sources: ['epa'] }; years.set(yk, y); }
    y.variants.push(x.v);
  }
  // vPIC: the manufacturer's spelling of a model EPA knows, model years EPA has no row for (1981 to 1983, the next model
  // year), and the models EPA does not rate (heavy-duty pickups and vans): every model of every year (the owner, October 22)
  const epaKeys = new Map<string, string[]>();
  for (const m of models.values()) epaKeys.set(m.make, [...(epaKeys.get(m.make) ?? []), m.key]);
  for (const [make, byYear] of opts.vpic ?? []) {
    if (!makes.has(make)) continue;
    for (const [year, names] of byYear) {
      // year 0: the make's whole list of model names, for their spelling only (no model year, no new model)
      const nameOnly = year === 0;
      if (!nameOnly && (year < opts.years[0] || year > opts.years[1])) continue;
      for (const name of names) {
        const key = modelKey(name);
        if (!key) continue;
        const mk = `${make}|${key}`;
        // a vPIC name that is an EPA model and a size ("Silverado 2500", "Sierra 1500 HD") is that model's year
        const family = (epaKeys.get(make) ?? []).filter((k) => k.length >= 3 && key.startsWith(k) && /^(\d{3,4}(hd)?|hd)$/.test(key.slice(k.length)))
          .sort((a, b) => b.length - a.length)[0];
        const m = models.get(mk) ?? [...models.values()].find((o) => o.make === make && o.aliases.has(key)) ?? (family ? models.get(`${make}|${family}`) : undefined);
        if (m && m.key !== key) m.aliases.add(key);
        if (!m && nameOnly) continue;
        const mm = m ?? (() => { const n = { make, name, key, aliases: new Set<string>(), vclass: [], sources: new Set(['vpic']) }; models.set(mk, n); return n; })();
        mm.sources.add('vpic');
        if (mm.key === key && /[-\s]/.test(name) && !/[-\s]/.test(mm.name)) mm.name = name; // "F-150", "CR-V", "CX-5"
        if (nameOnly) continue;
        const yk = `${make}|${mm.key}|${year}`;
        const y = years.get(yk);
        if (y) { if (!y.sources.includes('vpic')) y.sources.push('vpic'); }
        else years.set(yk, { make, model: mm.key, year, vclass: null, variants: [], sources: ['vpic'] });
      }
    }
  }
  // the further sources (0115): the vPIC database export, NRCan's ratings, Wikidata's older models (addExtra, below)
  const extraTrims = addExtra(opts.extra ?? [], makes, models, years);
  const modelRows: ModelRow[] = [...models.values()].map((m) => ({ make: m.make, slug: slugify(m.name), name: m.name, key: m.key, aliases: [...m.aliases].sort(), vclass: mode(m.vclass), sources: [...m.sources].sort() }));
  // two EPA base models with one slug (rare spelling differences) stay one page: the first name wins, aliases merge
  const bySlug = new Map<string, ModelRow>();
  const keyToSlug = new Map<string, string>();
  for (const m of modelRows.sort((a, b) => a.make.localeCompare(b.make) || a.key.localeCompare(b.key))) {
    const k = `${m.make}|${m.slug}`;
    const prev = bySlug.get(k);
    keyToSlug.set(`${m.make}|${m.key}`, m.slug);
    if (prev) { prev.aliases = [...new Set([...prev.aliases, ...m.aliases, m.key])].sort(); prev.sources = [...new Set([...prev.sources, ...m.sources])].sort(); }
    else bySlug.set(k, m);
  }
  const yearRows = new Map<string, YearRow>();
  for (const y of years.values()) {
    const slug = keyToSlug.get(`${y.make}|${y.model}`)!;
    const k = `${y.make}|${slug}|${y.year}`;
    const prev = yearRows.get(k);
    if (prev) { prev.variants.push(...y.variants); prev.sources = [...new Set([...prev.sources, ...y.sources])].sort(); }
    else yearRows.set(k, { ...y, model: slug, variants: [...y.variants] });
  }
  for (const y of yearRows.values()) {
    y.variants.sort((a, b) => a.id - b.id);
    y.vclass = mode(y.variants.map((v) => classOf(v.vclass))) ?? bySlug.get(`${y.make}|${y.model}`)?.vclass ?? null;
  }
  // trim lines and the popular list name models by name: matched by key or alias to the catalog's slug
  const resolve = (make: string, model: string) => {
    const k = modelKey(model);
    const direct = keyToSlug.get(`${make}|${k}`);
    if (direct) return direct;
    const viaAlias = [...bySlug.values()].find((m) => m.make === make && m.aliases.includes(k));
    return viaAlias?.slug ?? null;
  };
  const trim_lines = (opts.trimLines ?? []).map((t) => ({ ...t, model: resolve(t.make, t.model) ?? '' })).filter((t) => t.model);
  // a source's trims for the model years the curated list does not name (the curated list wins where it has the year)
  if (extraTrims.size) trim_lines.push(...extraTrimLines(extraTrims, keyToSlug, trim_lines));
  const popular = (opts.popular ?? []).map((p, i) => ({ make: p.make, model: resolve(p.make, p.model) ?? '', sort: i + 1 })).filter((p) => p.model);
  return {
    makes: [...makes].map(([slug, name]) => ({ slug, name })).sort((a, b) => a.slug.localeCompare(b.slug)),
    models: [...bySlug.values()], years: [...yearRows.values()].sort((a, b) => a.make.localeCompare(b.make) || a.model.localeCompare(b.model) || a.year - b.year),
    trim_lines, popular
  };
}

/** A make's models by every compact spelling the catalog knows (key, aliases), for names from other sources. */
function modelIndex(c: Catalog): Map<string, Map<string, string>> {
  const out = new Map<string, Map<string, string>>();
  for (const m of c.models) {
    const by = out.get(m.make) ?? out.set(m.make, new Map()).get(m.make)!;
    for (const k of [m.key, modelKey(m.slug), ...m.aliases]) if (k && !by.has(k)) by.set(k, m.slug);
  }
  return out;
}
/** The catalog model a name from another source starts with ("JETTA GLI 4DR SEDAN" is the Jetta): the longest run of
 *  its first words whose compact spelling the make has, and the words after it. */
export function modelOfName(idx: Map<string, string> | undefined, name: string): { slug: string; rest: string[] } | null {
  if (!idx) return null;
  const words = name.trim().split(/\s+/).filter(Boolean);
  let best: { slug: string; rest: string[] } | null = null;
  let acc = '';
  for (let i = 0; i < words.length && i < 5; i++) {
    acc += modelKey(words[i]!);
    const hit = idx.get(acc);
    if (hit) best = { slug: hit, rest: words.slice(i + 1) };
  }
  return best;
}
const twoDigitYear = (y: string) => { const n = Number(y); if (!Number.isFinite(n)) return null; return y.length === 4 ? n : n < 50 ? 2000 + n : 1900 + n; };

/** vPIC Canadian specifications (one per body and model year) as each catalog year's dims. */
export function attachDims(c: Catalog, cvs: Map<string, Array<Record<string, string>>>): number {
  const idx = modelIndex(c); const years = new Map(c.years.map((y) => [`${y.make}|${y.model}|${y.year}`, y]));
  const n = (s: string | undefined) => { const x = Number(String(s ?? '').trim()); return Number.isFinite(x) && x > 0 ? x : null; };
  let hit = 0;
  for (const [make, rows] of cvs) for (const r of rows) {
    const body = String(r.Model ?? '').trim(); const year = twoDigitYear(String(r.MYR ?? '').trim());
    const m = year ? modelOfName(idx.get(make), body) : null;
    const y = m ? years.get(`${make}|${m.slug}|${year}`) : undefined;
    if (!y) continue;
    const d: Dim = { body, length_cm: n(r.OL), width_cm: n(r.OW), height_cm: n(r.OH), wheelbase_cm: n(r.WB), curb_kg: n(r.CW) };
    y.dims ??= [];
    if (!y.dims.some((x) => x.body === d.body)) { y.dims.push(d); hit++; }
  }
  for (const y of c.years) y.dims?.sort((a, b) => a.body.localeCompare(b.body));
  return hit;
}

/** NHTSA recalls and complaint counts, keyed "make|MODEL TEXT|year" by the import, as each catalog year's. */
export function attachSafety(c: Catalog, recalls: Map<string, Recall[]>, complaints: Map<string, { total: number; comps: Map<string, number> }>): { recalls: number; complaints: number } {
  const idx = modelIndex(c); const years = new Map(c.years.map((y) => [`${y.make}|${y.model}|${y.year}`, y]));
  const find = (k: string) => { const [make, model, year] = k.split('|'); const m = modelOfName(idx.get(make!), model!); return m && m.rest.length <= 2 ? years.get(`${make}|${m.slug}|${year}`) : undefined; };
  let nr = 0, nc = 0;
  for (const [k, list] of recalls) {
    const y = find(k); if (!y) continue;
    y.recalls ??= [];
    for (const r of list) if (!y.recalls.some((x) => x.campaign === r.campaign)) { y.recalls.push(r); nr++; }
  }
  for (const [k, v] of complaints) {
    const y = find(k); if (!y) continue;
    const prev = y.complaints ?? { total: 0, components: [] };
    const comps = new Map(prev.components.map((x) => [x.component, x.n]));
    for (const [comp, cnt] of v.comps) comps.set(comp, (comps.get(comp) ?? 0) + cnt);
    y.complaints = { total: prev.total + v.total, components: [...comps].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 6).map(([component, n]) => ({ component, n })) };
    nc += v.total;
  }
  // every year of the catalog was looked up: none found is "none" (0), not "unknown"
  for (const y of c.years) { y.recalls ??= []; y.complaints ??= { total: 0, components: [] }; }
  for (const y of c.years) y.recalls?.sort((a, b) => String(b.date).localeCompare(String(a.date)) || a.campaign.localeCompare(b.campaign));
  return { recalls: nr, complaints: nc };
}

/**
 * The CarmaCars trim list (web/scripts/catalog/canada-trims.txt): one line per model and run of years,
 *   make | model | 2019-2021 | Comfortline, Highline, Sportline, Execline
 * in the order of the lineup (entry first). "#" starts a comment. Unknown makes are refused, so a typo is found.
 */
export function parseTrimList(text: string): TrimLine[] {
  const out: TrimLine[] = [];
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) return;
    const [make, model, span, trims] = line.split('|').map((s) => s.trim());
    const m = /^(\d{4})(?:-(\d{4}))?$/.exec(span ?? '');
    if (!make || !model || !m || !trims) throw new Error(`canada-trims line ${i + 1}: expected "make | model | 2019-2021 | Trim, Trim"`);
    const mk = slugify(make);
    if (!mk) throw new Error(`canada-trims line ${i + 1}: no make`);
    const list = trims.split(',').map((s) => s.trim()).filter(Boolean);
    if (new Set(list.map(trimSlug)).size !== list.length) throw new Error(`canada-trims line ${i + 1}: a trim is named twice`);
    out.push({ make: mk, model, from: Number(m[1]), to: Number(m[2] ?? m[1]), trims: list });
  });
  return out;
}

/** The popular list (web/scripts/catalog/popular.txt): "make | model" per line, most popular first. */
export function parsePopular(text: string): Array<{ make: string; model: string }> {
  return text.split(/\r?\n/).map((l) => l.replace(/#.*$/, '').trim()).filter(Boolean).map((l) => {
    const [make, model] = l.split('|').map((s) => s.trim());
    return { make: slugify(make), model: model ?? '' };
  }).filter((p) => p.make && p.model);
}

/** The import as batches for app.vehicle_catalog_import_batch: a make's models with their years, split so no call carries
 *  more than about `maxBytes` of JSON (a make of 40 years is several MB). The make's trim lines go with its first batch
 *  only (the database replaces them when a batch carries them). */
export type Batch = { make: MakeRow; models: ModelRow[]; years: YearRow[]; trim_lines?: TrimLine[] };
export function batches(c: Catalog, maxBytes = 900_000): Batch[] {
  const out: Batch[] = [];
  const yearsOf = new Map<string, YearRow[]>();
  for (const y of c.years) { const k = `${y.make}|${y.model}`; (yearsOf.get(k) ?? yearsOf.set(k, []).get(k)!).push(y); }
  for (const make of c.makes) {
    let cur: Batch = { make, models: [], years: [], trim_lines: c.trim_lines.filter((t) => t.make === make.slug) };
    let size = JSON.stringify(cur).length;
    for (const m of c.models.filter((x) => x.make === make.slug)) {
      const ys = yearsOf.get(`${m.make}|${m.slug}`) ?? [];
      const add = JSON.stringify(m).length + JSON.stringify(ys).length + 2;
      if (cur.models.length && size + add > maxBytes) { out.push(cur); cur = { make, models: [], years: [] }; size = JSON.stringify(cur).length; }
      cur.models.push(m); cur.years.push(...ys); size += add;
    }
    out.push(cur);
  }
  return out;
}

// ---------------------------------------------------------------- further sources (0115, docs/seo/coverage-2026-10-23.md)
// Each is optional and read only when the import is given its file or flag (web/scripts/catalog/import.mjs):
// - vpicdb: NHTSA's vPIC database (public domain) exported as make, model, year, vehicle type and trim: the makes,
//   models and years EPA does not rate (heavy trucks, buses, motorcycles when asked, low-volume makes) and the trim
//   names the VIN patterns carry;
// - nrcan: Natural Resources Canada's Fuel Consumption Ratings (Open Government Licence - Canada), 1995 on: the
//   Canadian-market models and years, with their Canadian figures where EPA has none for that year;
// - wikidata: car models before 1981 with their production years (CC0), names only.
export type ExtraRow = { make: string; model: string; year: number; trim?: string | null; vclass?: string | null; variant?: Variant | null };
export type ExtraSource = { source: 'vpicdb' | 'nrcan' | 'wikidata'; rows: ExtraRow[]; newMakes: boolean; years: [number, number] };
type ModelWork = { make: string; name: string; key: string; aliases: Set<string>; vclass: Array<string | null>; sources: Set<string> };

/** A source's rows into the catalog being built: a model by its key, an alias or its family ("Sierra 2500 HD" is the
 *  Sierra's), else a new model; the year added or marked; the figures only where EPA has none for that year. Returns the
 *  trims named per make|model key|year, in the order first seen. */
function addExtra(sources: ExtraSource[], makes: Map<string, string>, models: Map<string, ModelWork>, years: Map<string, YearRow>): Map<string, string[]> {
  const trims = new Map<string, string[]>();
  for (const src of sources) {
    const byMake = new Map<string, ModelWork[]>();
    for (const m of models.values()) (byMake.get(m.make) ?? byMake.set(m.make, []).get(m.make)!).push(m);
    for (const r of src.rows) {
      const name = makeName(r.make); const make = name ? slugify(name) : '';
      if (!make || !Number.isInteger(r.year) || r.year < src.years[0] || r.year > src.years[1]) continue;
      if (!makes.has(make)) { if (!src.newMakes) continue; makes.set(make, name!); }
      const label = cleanModelName(r.model);
      const key = modelKey(label);
      if (!key) continue;
      const list = byMake.get(make) ?? byMake.set(make, []).get(make)!;
      const known = (k: string) => models.get(`${make}|${k}`) ?? list.find((o) => o.aliases.has(k));
      let m = known(key) ?? list.filter((o) => o.key.length >= 3 && key.startsWith(o.key) && /^(\d{3,4}(hd)?|hd)$/.test(key.slice(o.key.length))).sort((a, b) => b.key.length - a.key.length)[0];
      if (m && m.key !== key) m.aliases.add(key);
      // else the longest run of its first words that is a model ("Sierra AT4" is the Sierra's): the rest names a trim or
      // a body, not a model of its own
      if (!m) { const ws = label.split(' '); let acc = ''; for (let i = 0; i < ws.length - 1 && i < 4; i++) { acc += modelKey(ws[i]); const hit = acc.length >= 2 ? known(acc) : undefined; if (hit) m = hit; } }
      if (!m) { m = { make, name: label, key, aliases: new Set(), vclass: [], sources: new Set() }; models.set(`${make}|${key}`, m); list.push(m); }
      m.sources.add(src.source);
      if (r.vclass) m.vclass.push(classOf(r.vclass));
      const yk = `${make}|${m.key}|${r.year}`;
      let y = years.get(yk);
      if (!y) { y = { make, model: m.key, year: r.year, vclass: null, variants: [], sources: [src.source] }; years.set(yk, y); }
      else if (!y.sources.includes(src.source)) y.sources.push(src.source);
      if (r.variant && y.variants.every((v) => v.src === 'nrcan')) y.variants.push(r.variant);
      for (const t of splitTrims(r.trim, label)) {
        const tl = trims.get(yk) ?? trims.set(yk, []).get(yk)!;
        if (!tl.some((x) => trimSlug(x) === trimSlug(t))) tl.push(t);
      }
    }
  }
  return trims;
}

/** A model name from another source without drive, body and fuel-system words ("F-150 FFV 4X4" is "F-150"); kept as
 *  it is when nothing would be left. */
export function cleanModelName(s: string): string {
  const words = String(s ?? '').replace(/\s+/g, ' ').trim().split(' ');
  const kept = words.filter((w, i) => i === 0 || !(GENERIC.has(modelKey(w)) || /^(\d(wd|dr)|4x[24]|ffv|lwb|swb|hev|phev|bev)$/i.test(w)));
  return (kept.join(' ') || words.join(' ')).replace(/[\s,;]+$/, '');
}

/** The trim names in one source value ("LX; EX / EX-L", "Sport,Touring"), at most 40 characters each, less the model's
 *  own name and words that say nothing ("N/A", "-", "Not Applicable"). */
export function splitTrims(v: string | null | undefined, model: string): string[] {
  const out: string[] = [];
  for (const raw of String(v ?? '').split(/;|,|\s\/\s/)) {
    const t = raw.replace(/\s+/g, ' ').trim();
    if (!t || t.length > 40 || !/[a-z0-9]/i.test(t) || /^(n\/?a|none|not applicable|unknown|-+|\.+)$/i.test(t) || modelKey(t) === modelKey(model) || !trimSlug(t)) continue;
    if (!out.some((x) => trimSlug(x) === trimSlug(t))) out.push(t);
  }
  return out;
}

/** The trims per model year as trim lines (runs of years with the same names become one line, 40 names at most), for
 *  the model years no curated line covers. */
function extraTrimLines(trims: Map<string, string[]>, keyToSlug: Map<string, string>, curated: TrimLine[]): TrimLine[] {
  const covered = (make: string, model: string, year: number) => curated.some((t) => t.make === make && t.model === model && year >= t.from && year <= t.to);
  const byModel = new Map<string, Array<{ year: number; names: string[] }>>();
  for (const [k, names] of trims) {
    const [make, key, y] = k.split('|'); const slug = keyToSlug.get(`${make}|${key}`); const year = Number(y);
    if (!slug || !names.length || covered(make!, slug, year)) continue;
    const mk = `${make}|${slug}`;
    (byModel.get(mk) ?? byModel.set(mk, []).get(mk)!).push({ year, names: names.slice(0, 40) });
  }
  const out: TrimLine[] = [];
  for (const [mk, ys] of [...byModel].sort((a, b) => a[0].localeCompare(b[0]))) {
    const [make, model] = mk.split('|') as [string, string];
    ys.sort((a, b) => a.year - b.year);
    for (const y of ys) {
      const last = out[out.length - 1];
      if (last && last.make === make && last.model === model && last.to === y.year - 1 && last.trims.join('|') === y.names.join('|')) last.to = y.year;
      else out.push({ make, model, from: y.year, to: y.year, trims: [...y.names] });
    }
  }
  return out;
}

/** The vPIC types a vPIC export row may be, by the name vPIC gives them. */
export const VPIC_TYPES: Record<string, string> = {
  'passenger car': 'car', 'multipurpose passenger vehicle (mpv)': 'mpv', truck: 'truck', motorcycle: 'motorcycle', bus: 'bus',
  'low speed vehicle (lsv)': 'lsv', 'incomplete vehicle': 'incomplete', trailer: 'trailer', 'off road vehicle': 'offroad'
};
const VPIC_CLASS: Record<string, string> = { truck: 'Truck', motorcycle: 'Motorcycle', bus: 'Bus', lsv: 'Low Speed Vehicle', offroad: 'Off Road Vehicle' };
/** The vPIC database export (docs/seo/coverage-2026-10-23.md has the query): CSV or tab-separated text with the header
 *  make,model,year,vehicle_type,trim (NULL is empty). Only the types asked for (car, mpv, truck by default). */
export function parseVpicExport(text: string, types: Set<string> = new Set(['car', 'mpv', 'truck'])): ExtraRow[] {
  const out: ExtraRow[] = [];
  // sqlcmd writes tab-separated text (the doc's export): read either
  const first = text.replace(/^\uFEFF/, '').split(/\r?\n/, 1)[0] ?? '';
  const table = first.includes('\t') && !first.includes(',')
    ? (() => { const [h, ...ls] = text.replace(/^\uFEFF/, '').split(/\r?\n/).filter((l) => l.trim() && !/^-+(\t-+)*$/.test(l.trim())); const head = h!.split('\t').map((x) => x.trim());
        return ls.map((l) => { const c = l.split('\t'); return Object.fromEntries(head.map((k, i) => [k, (c[i] ?? '').trim() === 'NULL' ? '' : (c[i] ?? '').trim()])); }); })()
    : parseCsv(text);
  for (const r of table) {
    const t = VPIC_TYPES[String(pick(r, 'vehicle_type') ?? '').trim().toLowerCase()] ?? String(pick(r, 'vehicle_type') ?? '').trim().toLowerCase();
    if (!types.has(t)) continue;
    const year = num(pick(r, 'year'));
    const make = String(pick(r, 'make') ?? '').trim(), model = String(pick(r, 'model') ?? '').trim();
    if (!year || !make || !model) continue;
    out.push({ make, model, year, trim: String(pick(r, 'trim') ?? '').trim() || null, vclass: VPIC_CLASS[t] ?? null });
  }
  return out;
}

/** NRCan's transmission code as EPA words: AS8 "Automatic (S8)", AV "Automatic (variable gear ratios)", M6 "Manual 6-spd". */
export function nrcanTrans(code: string): string | null {
  const m = /^(AM|AS|AV|A|M)(\d{0,2})$/i.exec(String(code ?? '').trim());
  if (!m) return null;
  const k = m[1]!.toUpperCase(), n = m[2] ?? '';
  if (k === 'AV') return n ? `Automatic (AV-S${n})` : 'Automatic (variable gear ratios)';
  if (k === 'M') return n ? `Manual ${n}-spd` : 'Manual';
  if (k === 'AS') return `Automatic (S${n})`;
  if (k === 'AM') return `Automatic (AM${n})`;
  return n ? `Automatic ${n}-spd` : 'Automatic';
}
const NRCAN_FUEL: Record<string, string> = { X: 'gasoline', Z: 'premium', D: 'diesel', E: 'gasoline', N: 'gasoline', B: 'electric' };
/** NRCan's Fuel Consumption Ratings (one CSV per file: the conventional, battery-electric or plug-in hybrid lists). The
 *  header is found by its words (the files differ by year: "Model year" or "MODEL YEAR", one or two header lines), and
 *  each row becomes a model year with its Canadian figures as a powertrain marked src 'nrcan'. */
export function parseNrcanCsv(text: string): ExtraRow[] {
  const lines = csvRows(text);
  const hi = lines.findIndex((r) => r.some((c) => /^make$/i.test(c.trim())) && r.some((c) => /^model/i.test(c.trim()) && !/year/i.test(c)));
  if (hi < 0) return [];
  // a second header line ("(L/100 km)" under "City") is joined to the first
  const sub = lines[hi + 1] && !lines[hi + 1]!.some((c) => /^\d{4}$/.test(c.trim())) ? lines[hi + 1]! : null;
  const head = lines[hi]!.map((c, i) => `${c} ${sub?.[i] ?? ''}`.replace(/\s+/g, ' ').trim().toLowerCase());
  const col = (re: RegExp, not?: RegExp) => head.findIndex((h) => re.test(h) && !(not && not.test(h)));
  const c = {
    year: col(/model.?year|^year/), make: col(/^make/), model: col(/^model(?!.?year)/), vclass: col(/class/), displ: col(/engine size/), cyl: col(/cylinder/),
    trans: col(/transmission/), fuel: col(/fuel( type)?$|fuel type/, /consumption/), city: col(/city/, /mpg|le\/|kwh/), hwy: col(/hwy|highway/, /mpg|le\/|kwh/),
    comb: col(/comb/, /mpg|le\/|kwh/), kwhComb: col(/comb.*kwh/), co2: col(/co2 emissions|co2.*g\/km/), range: col(/range/)
  };
  if (c.make < 0 || c.model < 0 || c.year < 0) return [];
  // the plug-in hybrid list has a second fuel (its L/100 km figures are the gasoline ones)
  const phevFile = head.some((h) => /fuel type 2/.test(h));
  const at = (r: string[], i: number) => (i >= 0 ? String(r[i] ?? '').trim() : '');
  const n = (s: string) => { const x = Number(s.replace(/[^0-9.]/g, '')); return s && Number.isFinite(x) && x > 0 ? x : null; };
  const out: ExtraRow[] = [];
  let id = 0;
  for (const r of lines.slice(hi + (sub ? 2 : 1))) {
    const year = Number(at(r, c.year)); const make = at(r, c.make); const model = at(r, c.model);
    if (!/^\d{4}$/.test(at(r, c.year)) || !make || !model) continue;
    const fuelCode = at(r, c.fuel).toUpperCase().split('/')[0]!;
    const phev = phevFile;
    const ev = !phev && (fuelCode === 'B' || (c.kwhComb >= 0 && !!n(at(r, c.kwhComb)) && !n(at(r, c.displ))));
    const words = model.toUpperCase();
    const drive = /\b(AWD|4MATIC|XDRIVE|QUATTRO|4MOTION|SH-AWD|ALL4)\b/.test(words) ? 'All-Wheel Drive' : /\b(4WD|4X4)\b/.test(words) ? '4-Wheel Drive' : null;
    id++;
    out.push({ make, model, year, vclass: at(r, c.vclass) || null, variant: {
      id: -(year * 100000 + id), epa_model: model, special: [], displ: ev ? null : n(at(r, c.displ)), cyl: ev ? null : n(at(r, c.cyl)), turbo: false, super: false,
      drive, trans: nrcanTrans(at(r, c.trans)), fuel: ev ? 'electric' : phev ? 'plug_in_hybrid' : (NRCAN_FUEL[fuelCode] ?? 'gasoline'), vclass: at(r, c.vclass) || null,
      l100_city: ev ? null : n(at(r, c.city)), l100_hwy: ev ? null : n(at(r, c.hwy)), l100_comb: ev ? null : n(at(r, c.comb)),
      kwh100: ev ? n(at(r, c.kwhComb >= 0 ? c.kwhComb : c.comb)) : null, ev_range_km: ev || phev ? n(at(r, c.range)) : null,
      co2_g_km: ev ? 0 : n(at(r, c.co2)), src: 'nrcan'
    } });
  }
  return out;
}
/** Wikidata's car models (CC0) from the SPARQL query in docs/seo/coverage-2026-10-23.md, as its JSON results: the
 *  manufacturer's and the model's English labels and the first and last production years. One model year a year of
 *  production, before 1981 only (vPIC and EPA have every year since), and twenty years at most a model. */
export function parseWikidata(json: unknown, until = 1980): ExtraRow[] {
  const b = (json as { results?: { bindings?: Array<Record<string, { value?: string }>> } })?.results?.bindings ?? [];
  const out: ExtraRow[] = [];
  const seen = new Set<string>();
  for (const x of b) {
    const make = String(x.makeLabel?.value ?? '').trim().replace(/\s+(motor car company|motor company|motor corporation|motors corporation|motor works|motors|automobiles|automobile company|automotive|car company|corporation|company)$/i, '').trim();
    let model = String(x.modelLabel?.value ?? '').trim();
    const from = Number(String(x.start?.value ?? '').slice(0, 4)); const to = Number(String(x.end?.value ?? '').slice(0, 4)) || from;
    if (!make || !model || /^Q\d+$/.test(model) || !(from >= 1900 && from <= until)) continue;
    if (model.toLowerCase().startsWith(make.toLowerCase() + ' ')) model = model.slice(make.length + 1).trim();
    for (let y = from; y <= Math.min(to, until, from + 19); y++) {
      const k = `${make}|${model}|${y}`.toLowerCase();
      if (!seen.has(k)) { seen.add(k); out.push({ make, model, year: y }); }
    }
  }
  return out;
}
