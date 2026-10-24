#!/usr/bin/env node
// Stock photos for the vehicle pages (migration 0137; docs/changes/2026-10-24-seo-photos.md). For each make and model
// of the catalog (the fleet's models first, then the popular list, then the rest) it finds the model's generations on
// Wikidata, picks the best licensed photo of each generation on Wikimedia Commons (public domain, CC0, CC BY or CC BY-SA
// only: src/features/vehicles/stock-photos.ts), and with --write downloads the 1280 px thumbnail, converts it to WebP at
// 640 and 1280 px without its metadata (EXIF, GPS), stores it in the public bucket (vehicle-public,
// seo-photos/<make>/<model>/<years>-<sha>-<width>.webp) and saves the row with its author, licence and source in
// vehicle_stock_photos. Never a fleet car's photo, never into git.
//
// Polite to Wikimedia (https://meta.wikimedia.org/wiki/User-Agent_policy, https://www.mediawiki.org/wiki/API:Etiquette):
// one request at a time, at least a second apart, a User-Agent with a contact, maxlag=5 on the API, Retry-After obeyed
// on 429 and 503, the standard 1280 px thumbnail (never the original), and a time budget per run. Resumable: every model
// is recorded in vehicle_stock_photo_checks when done, and the next run starts with the models not yet checked.
//
//   node --experimental-strip-types --no-warnings scripts/seo-photos/run.mjs [options]
//     --targets popular        the popular list (scripts/catalog/popular.txt): no database needed (the dry run on a push)
//     --targets db             the database's list (app.stock_photo_targets), fleet and popular first (default with --write)
//     --models toyota/camry,.. only these (with --targets db)
//     --limit N                at most N models this run (default 400)
//     --minutes M              stop starting new models after M minutes (default 50)
//     --write                  download, convert, store and save (STORAGE_URL, SERVICE_KEY, and SQL_API_URL or
//                              SUPABASE_PROJECT_REF + SUPABASE_ACCESS_TOKEN)
//     --generic                also the generic photos of the place and service pages (scripts/seo-photos/generic.json)
//     --no-pending             skip the Admin's replace and pick-again requests (handled first with --write)
//     --samples N              dry run: convert the first N picks in memory to check the conversion
//     --manifest FILE          write what was chosen (JSON)
//     --run-url URL            the GitHub Actions run, kept with each check
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomBytes } from 'node:crypto';
import { authorUrl, generationRanges, licenceOk, pickBest, plainAuthor, scoreGeneric } from '../../src/features/vehicles/stock-photos.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (k, d = null) => { const i = args.indexOf(`--${k}`); return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : d; };
const flag = (k) => args.includes(`--${k}`);
const WRITE = flag('write');
const TARGETS = opt('targets', WRITE ? 'db' : 'popular');
const LIMIT = Number(opt('limit', '400'));
const BUDGET_MS = Number(opt('minutes', '50')) * 60_000;
const SAMPLES = Number(opt('samples', '0'));
const MANIFEST = opt('manifest');
const RUN_URL = opt('run-url');
const MODELS = (opt('models', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const SIZES = [640, 1280];
const T0 = Date.now();

const UA = 'CarmaCarsStockPhotos/1.0 (https://carmacars.ca; hello@carmacars.ca) node';

// ---------------------------------------------------------------- polite HTTP
let last = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const stats = { requests: 0, retries: 0, bytes: 0 };
async function polite(url, { json = true, tries = 5 } = {}) {
  for (let i = 0; ; i++) {
    const wait = last + GAP_MS - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    stats.requests++;
    let r;
    try {
      r = await fetch(url, { headers: { 'user-agent': UA, 'api-user-agent': UA, accept: json ? 'application/sparql-results+json, application/json' : 'image/*' }, signal: AbortSignal.timeout(60_000) });
    } catch (e) {
      if (i >= tries) throw e;
      stats.retries++; await sleep(5000 * (i + 1)); continue;
    }
    if (r.status === 429 || r.status === 503 || r.status === 502 || r.status === 504) {
      if (i >= tries) throw new Error(`${r.status} from ${new URL(url).host}`);
      stats.retries++;
      const ra = Number(r.headers.get('retry-after'));
      await sleep(Math.min(Number.isFinite(ra) && ra > 0 ? ra * 1000 : 10_000 * (i + 1), 120_000));
      continue;
    }
    if (!r.ok) throw new Error(`${r.status} from ${url.slice(0, 160)}`);
    if (!json) { const b = Buffer.from(await r.arrayBuffer()); stats.bytes += b.length; return b; }
    const body = await r.json();
    // the API's lag guard: wait and try again
    if (body?.error?.code === 'maxlag') {
      if (i >= tries) throw new Error('maxlag');
      stats.retries++; await sleep(Math.max(5, Number(r.headers.get('retry-after')) || 5) * 1000); continue;
    }
    return body;
  }
}
// the endpoints (WM_* only for the script's own offline test, scripts/seo-photos/mock.test.mjs)
const API = process.env.WM_COMMONS_API ?? 'https://commons.wikimedia.org/w/api.php';
const WD = process.env.WM_WIKIDATA_API ?? 'https://www.wikidata.org/w/api.php';
const SPARQL = process.env.WM_SPARQL ?? 'https://query.wikidata.org/sparql';
const GAP_MS = Number(process.env.WM_GAP_MS ?? 1000);
const qs = (o) => new URLSearchParams({ format: 'json', formatversion: '2', maxlag: '5', ...o }).toString();
const EXT = 'LicenseShortName|License|LicenseUrl|UsageTerms|Artist|Credit|AttributionRequired|Copyrighted|NonFree|Restrictions|ImageDescription|ObjectName|Categories|DateTimeOriginal';
const II = { prop: 'imageinfo', iiprop: 'url|size|mime|sha1|extmetadata', iiurlwidth: '1280', iiextmetadatafilter: EXT, iiextmetadatalanguage: 'en' };

const norm = (s) => String(s ?? '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '');
const CAR = /\b(automobile|car|cars|vehicle|sport utility|suv|crossover|pick-?up|truck|minivan|van|sedan|saloon|hatchback|coupe|coupé|roadster|convertible|wagon|estate|model|series|range|lineup|nameplate)\b/i;

/** Commons pages (from imageinfo) as candidates. */
function candidates(pages, extra = {}) {
  return (pages ?? []).filter((p) => p.imageinfo?.[0]).map((p) => {
    const ii = p.imageinfo[0];
    const meta = Object.fromEntries(Object.entries(ii.extmetadata ?? {}).map(([k, v]) => [k, String(v?.value ?? '')]));
    return { title: p.title, width: ii.width, height: ii.height, mime: ii.mime, meta, thumb: ii.thumburl ?? ii.url, thumbWidth: ii.thumbwidth ?? ii.width,
      page: ii.descriptionurl, sha1: ii.sha1, quality: /(^|\|)Quality images(\||$)/.test(meta.Categories ?? ''), ...extra };
  });
}
async function imageInfo(titles) {
  const out = [];
  for (let i = 0; i < titles.length; i += 40) {
    const b = await polite(`${API}?${qs({ action: 'query', titles: titles.slice(i, i + 40).join('|'), ...II })}`);
    out.push(...(b.query?.pages ?? []));
  }
  return out;
}
async function categoryFiles(cat, quality) {
  const c = cat.replace(/^Category:/i, '').replace(/"/g, '');
  const q = quality
    ? { generator: 'search', gsrsearch: `incategory:"${c}" incategory:"Quality_images" filetype:bitmap`, gsrnamespace: '6', gsrlimit: '20' }
    : { generator: 'categorymembers', gcmtitle: `Category:${c}`, gcmtype: 'file', gcmlimit: '50' };
  const b = await polite(`${API}?${qs({ action: 'query', ...q, ...II })}`);
  return candidates(b.query?.pages, quality ? { quality: true } : {});
}

// ---------------------------------------------------------------- Wikidata: the model and its generations
async function resolveModel(make, model) {
  const want = norm(`${make} ${model}`);
  const b = await polite(`${WD}?${qs({ action: 'wbsearchentities', search: `${make} ${model}`, language: 'en', uselang: 'en', type: 'item', limit: '10' })}`);
  const hits = (b.search ?? []).filter((h) => CAR.test(h.description ?? '') && !/\b(company|manufacturer|brand|video game|song|album|film|racing|race car|concept)\b/i.test(h.description ?? ''));
  return hits.find((h) => norm(h.label) === want) ?? hits.find((h) => norm(h.label) === norm(model) || (h.aliases ?? []).some((a) => norm(a) === want)) ?? null;
}
const GEN_WORD = /^(\(|[a-z]{1,3}\d|mk|mark|[ivx]+\b|\d+(st|nd|rd|th)\b|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|generation|gen\b|\d{4})/i;
async function generations(qid, modelLabel) {
  const q = `SELECT ?item ?itemLabel ?img ?cat ?start ?prec ?start2 ?prec2 ?end WHERE {
  { BIND(wd:${qid} AS ?item) } UNION { ?item wdt:P179|wdt:P279|wdt:P361 wd:${qid} . FILTER(?item != wd:${qid}) }
  OPTIONAL { ?item wdt:P18 ?img }
  OPTIONAL { ?item wdt:P373 ?cat }
  OPTIONAL { ?item p:P571/psv:P571 [ wikibase:timeValue ?start; wikibase:timePrecision ?prec ] }
  OPTIONAL { ?item p:P580/psv:P580 [ wikibase:timeValue ?start2; wikibase:timePrecision ?prec2 ] }
  OPTIONAL { ?item wdt:P2669|wdt:P582|wdt:P576 ?end }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
} LIMIT 300`;
  const b = await polite(`${SPARQL}?${new URLSearchParams({ query: q, format: 'json' })}`);
  const by = new Map();
  for (const r of b.results?.bindings ?? []) {
    const id = r.item.value.split('/').pop();
    const g = by.get(id) ?? { id, label: r.itemLabel?.value ?? id, start: null, startMonth: null, end: null, image: null, category: null };
    const st = r.start ?? r.start2, pr = Number((r.start ? r.prec : r.prec2)?.value ?? 9);
    if (st && g.start === null) { const d = new Date(st.value); if (!Number.isNaN(d.getTime())) { g.start = d.getUTCFullYear(); g.startMonth = pr >= 10 ? d.getUTCMonth() + 1 : null; } }
    if (r.end && g.end === null) { const d = new Date(r.end.value); if (!Number.isNaN(d.getTime())) g.end = d.getUTCFullYear(); }
    if (r.img && !g.image) g.image = `File:${decodeURIComponent(r.img.value.split('/Special:FilePath/').pop()).replace(/_/g, ' ')}`;
    if (r.cat && !g.category) g.category = r.cat.value;
    by.set(id, g);
  }
  const self = by.get(qid) ?? { id: qid, label: modelLabel, start: null, end: null, image: null, category: null };
  by.delete(qid);
  // a generation's name begins with the model's and goes on with a generation word ("Toyota Camry (XV70)"), never
  // another car ("Toyota Camry Solara", "Daihatsu Altis") or a race version
  const prefix = norm(self.label || modelLabel);
  const gens = [...by.values()].filter((g) => {
    if (!norm(g.label).startsWith(prefix)) return false;
    const rest = g.label.slice(g.label.toLowerCase().indexOf((self.label || modelLabel).toLowerCase()) + (self.label || modelLabel).length).trim();
    return (!rest || GEN_WORD.test(rest)) && !/nascar|race|racing|rally|concept|police|taxi|electric conversion/i.test(g.label);
  });
  return { self, gens };
}

// ---------------------------------------------------------------- one model
async function chooseFor(t, rejectedBy = new Map()) {
  const r = { make: t.make, model: t.model, wikidata: null, rows: [], note: '' };
  const hit = await resolveModel(t.make_name, t.model_name);
  if (!hit) { r.note = 'not found on Wikidata'; return r; }
  r.wikidata = hit.id;
  const { self, gens } = await generations(hit.id, hit.label);
  const first = t.first_year ?? 1980, lastY = t.last_year ?? new Date().getUTCFullYear() + 1;
  const ranges = generationRanges(gens, first, lastY);
  const slots = ranges.length ? ranges.map((g) => ({ g, from: g.from, to: g.to })) : [{ g: self, from: null, to: null }];
  // the Wikidata images of every generation (and the model) in one request
  const p18 = [...new Set([...slots.map((s) => s.g.image), self.image].filter(Boolean))];
  const info = new Map(candidates(p18.length ? await imageInfo(p18) : []).map((c) => [c.title, c]));
  for (const s of slots) {
    const key = s.from ?? 0;
    const ctx = { make: t.make_name, model: t.model_name, yearFrom: s.from, yearTo: s.to, rejected: rejectedBy.get(key) ?? [] };
    const pool = [];
    if (s.g.image && info.get(s.g.image)) pool.push({ ...info.get(s.g.image), wikidata: true });
    let best = pickBest(pool, ctx);
    const cat = s.g.category ?? (ranges.length ? null : self.category);
    if (cat && (!best || best.score < 75)) { pool.push(...await categoryFiles(cat, true)); best = pickBest(pool, ctx); }
    if (cat && (!best || best.score < 55)) { pool.push(...await categoryFiles(cat, false)); best = pickBest(pool, ctx); }
    if (!best) continue;
    r.rows.push(rowOf(best, s, cat));
  }
  r.note = `${gens.length} generation${gens.length === 1 ? '' : 's'} on Wikidata, ${ranges.length} dated in the catalog's years, ${r.rows.length} photo${r.rows.length === 1 ? '' : 's'}`;
  return r;
}
function rowOf(best, s, cat) {
  const c = best.c, lic = licenceOk(c.meta);
  return {
    year_from: s.from, year_to: s.to, generation: s.g.label ?? null, wikidata: s.g.id ?? null, category: cat ?? null,
    file_title: c.title, source_url: c.page ?? `https://commons.wikimedia.org/wiki/${encodeURI(c.title.replace(/ /g, '_'))}`, width: c.width, height: c.height,
    author: plainAuthor(c.meta.Artist) || 'Unknown author', author_url: authorUrl(c.meta.Artist), licence: lic.licence, licence_url: lic.licenceUrl,
    sha1: c.sha1 ?? null, score: best.score, thumb: c.thumb, thumb_width: c.thumbWidth
  };
}

// ---------------------------------------------------------------- convert and store
let sharp = null;
async function convert(buf) {
  sharp ??= (await import('sharp')).default;
  const meta = await sharp(buf).metadata();
  const out = [];
  for (const w of SIZES) {
    // never enlarged: a photo under 1280 px is stored at its own width
    const width = Math.min(w, meta.width ?? w);
    if (out.some((o) => o.width === width)) continue;
    // rotate() applies the camera's orientation; the output carries no metadata (sharp strips EXIF, GPS, XMP by default)
    const { data, info } = await sharp(buf).rotate().resize({ width, withoutEnlargement: true }).webp({ quality: 78, effort: 5 }).toBuffer({ resolveWithObject: true });
    out.push({ width: info.width, height: info.height, data });
  }
  return out;
}
const STORAGE = process.env.STORAGE_URL, KEY = process.env.SERVICE_KEY;
async function put(path, data) {
  const r = await fetch(`${STORAGE}/object/vehicle-public/${path}`, { method: 'POST', headers: { authorization: `Bearer ${KEY}`, apikey: KEY, 'content-type': 'image/webp',
    'cache-control': 'max-age=31536000', 'x-upsert': 'true' }, body: data, signal: AbortSignal.timeout(120_000) });
  if (!r.ok) throw new Error(`storage ${r.status}: ${(await r.text()).slice(0, 200)}`);
}
async function removeFiles(paths) {
  if (!paths.length) return;
  const r = await fetch(`${STORAGE}/object/vehicle-public`, { method: 'DELETE', headers: { authorization: `Bearer ${KEY}`, apikey: KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ prefixes: paths }), signal: AbortSignal.timeout(60_000) });
  if (!r.ok) console.log(`warning: could not remove ${paths.length} old files (${r.status})`);
}
const seg = (s) => String(s).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '') || 'x';
/** Downloads the 1280 px thumbnail, converts it and stores both widths. Adds path, sizes, width, height to the row. */
async function store(where, row) {
  const buf = await polite(row.thumb, { json: false });
  try {
    const sized = await convert(buf);
    const h = createHash('sha256').update(buf).digest('hex').slice(0, 10);
    const base = `seo-photos/${where}/${row.year_from ? `${row.year_from}-${row.year_to}` : 'model'}-${h}`;
    for (const s of sized) await put(`${base}-${s.width}.webp`, s.data);
    const big = sized[sized.length - 1];
    Object.assign(row, { path: base, sizes: sized.map((s) => s.width), width: big.width, height: big.height });
  } finally { buf.fill(0); }
}

// ---------------------------------------------------------------- the database (the catalog workflow's way)
const lit = (o) => { const j = JSON.stringify(o); const t = j.includes('$sp$') ? `$p${randomBytes(4).toString('hex')}$` : '$sp$'; return `${t}${j}${t}::jsonb`; };
async function sql(query) {
  const api = process.env.SQL_API_URL, ref = process.env.SUPABASE_PROJECT_REF, token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!api && (!ref || !token)) throw new Error('SQL_API_URL, or SUPABASE_PROJECT_REF and SUPABASE_ACCESS_TOKEN, are needed');
  const r = await fetch(api ?? `https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: 'POST', headers: { ...(api ? {} : { authorization: `Bearer ${token}` }), 'content-type': 'application/json' }, body: JSON.stringify({ query }), signal: AbortSignal.timeout(120_000) });
  const text = await r.text();
  if (!r.ok) throw new Error(`SQL failed (${r.status}): ${text.slice(0, 400)}`);
  const rows = JSON.parse(text);
  return Array.isArray(rows) ? rows : rows?.result ?? [];
}
const one = async (q) => Object.values((await sql(q))[0] ?? {})[0] ?? null;

// ---------------------------------------------------------------- targets
function popularTargets() {
  return readFileSync(join(HERE, '..', 'catalog', 'popular.txt'), 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#')).map((l) => {
    const [mk, md] = l.split('|').map((s) => s.trim());
    return { make: seg(mk), model: seg(md), make_name: mk, model_name: md, first_year: 2000, last_year: new Date().getUTCFullYear() + 1, existing: [] };
  }).filter((t) => !MODELS.length || MODELS.includes(`${t.make}/${t.model}`));
}

// ---------------------------------------------------------------- main
const run = { started: new Date().toISOString(), mode: WRITE ? 'write' : 'dry', targets: TARGETS, models: 0, found: 0, photos: 0, stored: 0, failed: 0, missing: [], picks: [], generic: [], pending: 0, errors: [] };
const out = (s) => console.log(s);
let runId = null;
if (WRITE) {
  if (!STORAGE || !KEY) throw new Error('STORAGE_URL and SERVICE_KEY are needed to write');
  runId = await one(`select app.stock_photo_run_begin(${lit({ mode: 'write', run_url: RUN_URL })})`);
}

// the Admin's requests first: a named file to use instead, or "pick again" without the rejected files
if (WRITE && !flag('no-pending')) {
  const pending = (await one('select app.stock_photo_pending()')) ?? [];
  for (const p of pending) {
    if (Date.now() - T0 > BUDGET_MS) break;
    run.pending++;
    try {
      let row = null, note = '';
      if (p.want_file) {
        let name = String(p.want_file).trim().replace(/^.*\/wiki\//, '').replace(/[?#].*$/, '');
        try { name = decodeURIComponent(name); } catch { /* already plain */ }
        const title = `File:${name.replace(/^File:/i, '').replace(/_/g, ' ')}`;
        const c = candidates(await imageInfo([title]))[0];
        const lic = c ? licenceOk(c.meta) : { ok: false, reason: 'no such file on Commons' };
        if (!c || !lic.ok) note = `Not used: ${c ? lic.reason : 'no such file on Commons'}`;
        else if (!/^image\/(jpeg|png|webp)$/.test(c.mime) || c.width < 640) note = 'Not used: a JPEG, PNG or WebP photo at least 640 px wide is needed';
        else if (lic.attribution && !plainAuthor(c.meta.Artist)) note = 'Not used: the file names no author';
        else row = rowOf({ c, score: null }, { g: { label: p.generation, id: p.wikidata }, from: p.year_from, to: p.year_to }, p.category);
      } else {
        const pool = [];
        if (p.category) pool.push(...await categoryFiles(p.category, true), ...await categoryFiles(p.category, false));
        const best = pickBest(pool, { make: p.make_name ?? p.make, model: p.model_name ?? p.model, yearFrom: p.year_from, yearTo: p.year_to, rejected: p.rejected_files ?? [] });
        if (best) row = rowOf(best, { g: { label: p.generation, id: p.wikidata }, from: p.year_from, to: p.year_to }, p.category);
        else note = 'No other licensed photo found: upload one to Commons, or name a file';
      }
      if (row) await store(`${seg(p.make)}/${seg(p.model)}`, row);
      const old = await one(`select app.stock_photo_resolve(${lit({ id: p.id, row, note, run_id: runId })})`);
      if (row) run.stored++;
      await removeFiles((old ?? []).flatMap((o) => (o.sizes ?? []).map((w) => `${o.path}-${w}.webp`)));
      out(`pending ${p.make}/${p.model} ${p.year_from ?? ''}: ${row ? row.file_title : note}`);
    } catch (e) { run.errors.push(`pending ${p.id}: ${e.message}`); run.failed++; }
  }
}

const targets = TARGETS === 'db' ? ((await one(`select app.stock_photo_targets(${lit({ limit: LIMIT, models: MODELS })})`)) ?? []) : popularTargets().slice(0, LIMIT);
out(`targets: ${targets.length} models (${TARGETS})`);
for (const t of targets) {
  if (Date.now() - T0 > BUDGET_MS) { out(`time budget reached after ${run.models} models`); break; }
  run.models++;
  try {
    const rejected = new Map((t.existing ?? []).map((e) => [e.year_from ?? 0, e.rejected_files ?? []]));
    const r = await chooseFor(t, rejected);
    if (r.wikidata) run.found++;
    if (!r.rows.length) run.missing.push(`${t.make_name} ${t.model_name}`);
    run.photos += r.rows.length;
    if (WRITE) {
      const have = new Map((t.existing ?? []).map((e) => [`${e.year_from ?? 0}`, e]));
      for (const row of r.rows) {
        const e = have.get(`${row.year_from ?? 0}`);
        // the same file already stored, or a row an Admin chose or hid: kept as it is
        if (e && (e.picked_by === 'admin' || e.status === 'hidden' || (e.file_title === row.file_title && e.path))) { Object.assign(row, { keep: true }); continue; }
        try { await store(`${seg(t.make)}/${seg(t.model)}`, row); run.stored++; } catch (e2) { run.errors.push(`${t.make}/${t.model} ${row.file_title}: ${e2.message}`); row.failed = String(e2.message).slice(0, 200); run.failed++; }
      }
      const old = await one(`select app.stock_photo_save(${lit({ make: t.make, model: t.model, wikidata: r.wikidata, note: r.note, run_id: runId,
        rows: r.rows.filter((x) => !x.failed).map(({ thumb, thumb_width, ...x }) => x) })})`);
      await removeFiles((old ?? []).flatMap((o) => (o.sizes ?? []).map((w) => `${o.path}-${w}.webp`)));
    } else if (SAMPLES > 0 && run.picks.length < SAMPLES && r.rows[0]) {
      const buf = await polite(r.rows[0].thumb, { json: false });
      const sized = await convert(buf);
      out(`sample ${t.make}/${t.model}: ${sized.map((s) => `${s.width}x${s.height} ${Math.round(s.data.length / 1024)} KB`).join(', ')}`);
    }
    for (const row of r.rows) run.picks.push({ m: `${t.make}/${t.model}`, y: row.year_from ? `${row.year_from}-${row.year_to}` : '', g: row.generation, f: row.file_title.replace(/^File:/, ''),
      w: row.width, h: row.height, l: row.licence, a: row.author.slice(0, 40), s: row.score });
    out(`${t.make}/${t.model}: ${r.note}`);
  } catch (e) { run.errors.push(`${t.make}/${t.model}: ${e.message}`); run.failed++; out(`${t.make}/${t.model}: error ${e.message}`); }
}

// the place and service pages' generic photos (a few per kind of page)
if (flag('generic') && Date.now() - T0 < BUDGET_MS) {
  const slots = JSON.parse(readFileSync(join(HERE, 'generic.json'), 'utf8')).slots;
  for (const s of slots) {
    const pool = [];
    for (const q of s.queries) {
      const b = await polite(`${API}?${qs({ action: 'query', generator: 'search', gsrsearch: q, gsrnamespace: '6', gsrlimit: '20', ...II })}`);
      pool.push(...candidates(b.query?.pages));
    }
    const ranked = [...new Map(pool.map((c) => [c.title, c])).values()].map((c) => ({ c, score: scoreGeneric(c, s) })).filter((x) => x.score !== null).sort((a, b) => b.score - a.score).slice(0, s.keep ?? 4);
    const rows = ranked.map((x) => ({ ...rowOf(x, { g: { label: null, id: null }, from: null, to: null }, null), alt: s.alt }));
    if (WRITE) {
      for (const row of rows) { try { await store(`generic/${seg(s.slot)}`, row); } catch (e) { row.failed = e.message; run.errors.push(`generic ${s.slot}: ${e.message}`); } }
      const old = await one(`select app.stock_photo_save_generic(${lit({ slot: s.slot, run_id: runId, rows: rows.filter((r) => !r.failed).map(({ thumb, thumb_width, ...x }) => x) })})`);
      await removeFiles((old ?? []).flatMap((o) => (o.sizes ?? []).map((w) => `${o.path}-${w}.webp`)));
    }
    run.generic.push({ slot: s.slot, files: rows.map((r) => `${r.file_title.replace(/^File:/, '')} (${r.licence}, ${r.author.slice(0, 30)})`) });
    out(`generic ${s.slot}: ${rows.length}`);
  }
}

run.finished = new Date().toISOString();
run.http = stats;
if (WRITE) await one(`select app.stock_photo_run_finish(${lit({ id: runId, counts: { models: run.models, found: run.found, photos: run.photos, stored: run.stored, failed: run.failed, pending: run.pending,
  requests: stats.requests, megabytes: Math.round(stats.bytes / 1048576) }, errors: run.errors.slice(0, 50) })})`);
if (MANIFEST) writeFileSync(MANIFEST, JSON.stringify(run, null, 1));
out(`done: ${run.models} models, ${run.found} on Wikidata, ${run.photos} photos chosen, ${run.stored} stored, ${run.failed} failed, ${stats.requests} requests (${stats.retries} retried), ${Math.round(stats.bytes / 1048576)} MB downloaded`);
if (run.missing.length) out(`missing: ${run.missing.join(', ')}`);
