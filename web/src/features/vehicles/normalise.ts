// The vehicle catalog import (migration 0092, web/scripts/catalog/import.mjs): the US EPA fueleconomy.gov vehicles file
// (public domain) read into makes, models, model years and their powertrains; NHTSA vPIC model names (public domain)
// for coverage and names; the Canadian trims from the CarmaCars trim list (web/scripts/catalog/canada-trims.txt).
// Pure functions: no imports beyond ./units.ts, nothing read or written here.
import { kwh100miTo100km, miToKm, modelKey, mpgToL100, slugify, trimSlug } from './units.ts';

/** Makes sold new in Canada since 2010, as the EPA file spells them, with the name shown. Exotic makes are left out. */
export const CANADA_MAKES: Record<string, string> = {
  'Acura': 'Acura', 'Alfa Romeo': 'Alfa Romeo', 'Audi': 'Audi', 'BMW': 'BMW', 'Buick': 'Buick', 'Cadillac': 'Cadillac', 'Chevrolet': 'Chevrolet',
  'Chrysler': 'Chrysler', 'Dodge': 'Dodge', 'Fiat': 'Fiat', 'FIAT': 'Fiat', 'Ford': 'Ford', 'Genesis': 'Genesis', 'GMC': 'GMC', 'Honda': 'Honda', 'Hummer': 'Hummer',
  'Hyundai': 'Hyundai', 'Infiniti': 'Infiniti', 'Jaguar': 'Jaguar', 'Jeep': 'Jeep', 'Kia': 'Kia', 'Land Rover': 'Land Rover', 'Lexus': 'Lexus',
  'Lincoln': 'Lincoln', 'Lucid': 'Lucid', 'Mazda': 'Mazda', 'Mercedes-Benz': 'Mercedes-Benz', 'MINI': 'MINI', 'Mini': 'MINI', 'Mitsubishi': 'Mitsubishi',
  'Nissan': 'Nissan', 'Polestar': 'Polestar', 'Pontiac': 'Pontiac', 'Porsche': 'Porsche', 'Ram': 'Ram', 'Rivian': 'Rivian', 'Saab': 'Saab',
  'Saturn': 'Saturn', 'Scion': 'Scion', 'smart': 'smart', 'Subaru': 'Subaru', 'Suzuki': 'Suzuki', 'Tesla': 'Tesla', 'Toyota': 'Toyota',
  'VinFast': 'VinFast', 'Volkswagen': 'Volkswagen', 'Volvo': 'Volvo'
};

/** Words in an EPA model name that say the drive, the body or the cab, not the model or the trim. */
const GENERIC = new Set(['2wd', '4wd', 'awd', 'fwd', 'rwd', '4x4', '4x2', '4matic', '4matic+', 'xdrive', 'sdrive', 'quattro', '4motion', 'sh-awd', 'all4', 'e-four',
  'pickup', 'cab', 'chassis', 'sedan', 'coupe', 'convertible', 'cabriolet', 'roadster', 'hatchback', 'wagon', 'van', 'cargo', 'passenger', 'suv', 'crossover',
  'ffv', 'doors', '2dr', '4dr', '5dr', '3dr', 'door']);

export type Variant = {
  id: number; epa_model: string; special: string[]; displ: number | null; cyl: number | null; turbo: boolean; super: boolean;
  drive: string | null; trans: string | null; fuel: string; vclass: string | null;
  l100_city: number | null; l100_hwy: number | null; l100_comb: number | null; kwh100: number | null; ev_range_km: number | null; co2_g_km: number | null;
};
export type YearRow = { make: string; model: string; year: number; vclass: string | null; variants: Variant[]; sources: string[] };
export type ModelRow = { make: string; slug: string; name: string; key: string; aliases: string[]; vclass: string | null; sources: string[] };
export type MakeRow = { slug: string; name: string };
export type TrimLine = { make: string; model: string; from: number; to: number; trims: string[] };
export type Catalog = { makes: MakeRow[]; models: ModelRow[]; years: YearRow[]; trim_lines: TrimLine[]; popular: Array<{ make: string; model: string; sort: number }> };

/** RFC 4180 CSV (quoted fields, doubled quotes, CRLF), first row the header. */
export function parseCsv(text: string): Array<Record<string, string>> {
  const rows: string[][] = [];
  let row: string[] = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(field); field = ''; if (row.length > 1 || row[0] !== '') rows.push(row); row = []; }
    else field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  const head = (rows.shift() ?? []).map((h) => h.trim());
  return rows.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])));
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

/** The words of an EPA model name beyond its base model, less drive and body words: "Jetta GLI" gives ["gli"]. */
export function specialTokens(epaModel: string, baseModel: string): string[] {
  const m = slugify(epaModel), b = slugify(baseModel);
  const rest = b && (m === b || m.startsWith(b + '-')) ? m.slice(b.length) : (b && modelKey(epaModel).startsWith(modelKey(baseModel)) ? '' : m);
  return rest.split('-').filter((t) => t && !GENERIC.has(t) && !/^\d{1,2}(wd|dr)$/.test(t));
}

/** One EPA row as a powertrain, or null when it is outside the years or makes the site covers. */
export function variantOf(r: Record<string, string>, years: [number, number]): { make: string; makeName: string; base: string; year: number; v: Variant } | null {
  const year = num(pick(r, 'year'));
  const makeName = CANADA_MAKES[String(pick(r, 'make') ?? '').trim()];
  if (!year || year < years[0] || year > years[1] || !makeName) return null;
  const epaModel = String(pick(r, 'model') ?? '').trim();
  const base = String(pick(r, 'baseModel') ?? '').trim() || epaModel;
  if (!epaModel) return null;
  const fuel = fuelOf(r);
  const ev = fuel === 'electric';
  const tc = String(pick(r, 'tCharger') ?? '').trim(), sc = String(pick(r, 'sCharger') ?? '').trim();
  const rng = num(pick(r, 'range')) || (fuel === 'plug_in_hybrid' ? num(String(pick(r, 'rangeA') ?? '').split('/')[0]) : null);
  const co2 = num(pick(r, 'co2TailpipeGpm'));
  return {
    make: slugify(makeName), makeName, base, year,
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
      co2_g_km: co2 && co2 > 0 ? Math.round(co2 / 1.609344) : (ev ? 0 : null)
    }
  };
}

/** The size class without the drive ("Small Sport Utility Vehicle 4WD" is "Small Sport Utility Vehicle"). */
export const classOf = (s: string | null) => (s ? s.replace(/\s+[24]WD$/i, '').replace(/\s*-\s*[24]WD$/i, '').trim() : null);
const mode = (xs: Array<string | null>) => { const n = new Map<string, number>(); for (const x of xs) if (x) n.set(x, (n.get(x) ?? 0) + 1); return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0]?.[0] ?? null; };

/** vPIC's names for a make's models (by year): used for the shown name ("F-150" over EPA's "F150") and for coverage. */
export type VpicNames = Map<string, Map<number, string[]>>; // make slug -> year -> model names

/** The EPA rows and vPIC names as the catalog. vPIC adds years only to models EPA knows or the trim list names. */
export function buildCatalog(rows: Array<Record<string, string>>, opts: { years: [number, number]; vpic?: VpicNames; trimLines?: TrimLine[]; popular?: Array<{ make: string; model: string }> }): Catalog {
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
  // vPIC: the manufacturer's spelling of a model EPA knows, and model years EPA has no row for
  const named = new Set((opts.trimLines ?? []).map((t) => `${t.make}|${modelKey(t.model)}`));
  for (const [make, byYear] of opts.vpic ?? []) {
    if (!makes.has(make)) continue;
    for (const [year, names] of byYear) {
      // year 0: the make's whole list of model names, for their spelling only (no model year, no new model)
      const nameOnly = year === 0;
      if (!nameOnly && (year < opts.years[0] || year > opts.years[1])) continue;
      for (const name of names) {
        const key = modelKey(name);
        const mk = `${make}|${key}`;
        const m = models.get(mk) ?? [...models.values()].find((o) => o.make === make && o.aliases.has(key));
        if (!m && (nameOnly || !named.has(mk))) continue;
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
  const popular = (opts.popular ?? []).map((p, i) => ({ make: p.make, model: resolve(p.make, p.model) ?? '', sort: i + 1 })).filter((p) => p.model);
  return {
    makes: [...makes].map(([slug, name]) => ({ slug, name })).sort((a, b) => a.slug.localeCompare(b.slug)),
    models: [...bySlug.values()], years: [...yearRows.values()].sort((a, b) => a.make.localeCompare(b.make) || a.model.localeCompare(b.model) || a.year - b.year),
    trim_lines, popular
  };
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
    if (!Object.values(CANADA_MAKES).some((n) => slugify(n) === mk)) throw new Error(`canada-trims line ${i + 1}: unknown make ${make}`);
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

/** The import as batches for app.vehicle_catalog_import_batch: one per make, so no call carries the whole catalog. */
export function batches(c: Catalog): Array<{ make: MakeRow; models: ModelRow[]; years: YearRow[]; trim_lines: TrimLine[] }> {
  return c.makes.map((make) => ({
    make, models: c.models.filter((m) => m.make === make.slug), years: c.years.filter((y) => y.make === make.slug), trim_lines: c.trim_lines.filter((t) => t.make === make.slug)
  }));
}
