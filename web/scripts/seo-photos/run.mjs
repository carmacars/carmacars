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
import { articleYears, authorUrl, categoryFor, firstModelYear, generationRanges, licenceOk, openverseMeta, parseGenerations, pickBest, plainAuthor, scoreGeneric,
  sourceShowsLicence } from '../../src/features/vehicles/stock-photos.ts';

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
// --shard i/n: only every n-th model from the i-th (the dry run splits the popular list over parallel jobs)
const [SHARD, SHARDS] = (opt('shard', '0/1') || '0/1').split('/').map(Number);
const SIZES = [640, 1280];
const T0 = Date.now();

const UA = 'CarmaCarsStockPhotos/1.0 (https://carmacars.ca; hello@carmacars.ca) node';

// ---------------------------------------------------------------- polite HTTP
let last = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const stats = { requests: 0, retries: 0, bytes: 0 };
/** What the generation search found per model (the dry run reports it). */
const diag = [];
async function polite(url, { json = true, tries = 5 } = {}) {
  for (let i = 0; ; i++) {
    const wait = last + GAP_MS - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    stats.requests++;
    let r;
    try {
      r = await fetch(url, { headers: { 'user-agent': UA, 'api-user-agent': UA, accept: json ? 'application/json' : 'image/*,text/html;q=0.9' }, signal: AbortSignal.timeout(60_000) });
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
    // Wikimedia's servers are behind: wait (Retry-After, longer each time, up to a minute) and try again, patiently
    // the wait Wikimedia asks for (Retry-After, 5 s by default), a few times; a model that still fails is taken again at
    // the end of the run, or at the next run
    if (body?.error?.code === 'maxlag') {
      stats.maxlag = (stats.maxlag ?? 0) + 1;
      if (i >= tries + 3) throw new Error(`maxlag (${new URL(url).host})`);
      stats.retries++; await sleep(Math.min(30, Math.max(5, Number(r.headers.get('retry-after')) || 5)) * 1000); continue;
    }
    return body;
  }
}
// the endpoints (WM_* only for the script's own offline check, scripts/seo-photos/offline-check.mjs)
const API = process.env.WM_COMMONS_API ?? 'https://commons.wikimedia.org/w/api.php';
const WD = process.env.WM_WIKIDATA_API ?? 'https://www.wikidata.org/w/api.php';
const WP = process.env.WM_WIKIPEDIA_API ?? 'https://en.wikipedia.org/w/api.php';
const OV = process.env.WM_OPENVERSE_API ?? 'https://api.openverse.org/v1';
const GAP_MS = Number(process.env.WM_GAP_MS ?? 1000);
const qs = (o) => new URLSearchParams({ format: 'json', formatversion: '2', maxlag: '5', ...o }).toString();
const EXT = 'LicenseShortName|License|LicenseUrl|UsageTerms|Artist|Credit|AttributionRequired|Copyrighted|NonFree|Restrictions|ImageDescription|ObjectName|Categories|DateTimeOriginal';
const II = { prop: 'imageinfo', iiprop: 'url|size|mime|sha1|extmetadata', iiurlwidth: '1280', iiextmetadatafilter: EXT, iiextmetadatalanguage: 'en' };

const norm = (s) => String(s ?? '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '');

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
// Wikidata's Action API only (the search, haswbstatement and wbgetentities): the same rate rules as Commons.
// disambiguation page, business, car maker, organization, company, software, film, video game (a car model is often also a trademark)
const NOT_A_CAR = new Set(['Q4167410', 'Q4830453', 'Q786820', 'Q43229', 'Q783794', 'Q7397', 'Q11424', 'Q7889']);
const claim = (e, p) => (e?.claims?.[p] ?? []).filter((c) => c.rank !== 'deprecated').map((c) => c.mainsnak?.datavalue?.value).filter((v) => v !== undefined && v !== null);
const ids = (e, p) => claim(e, p).map((v) => v?.id).filter(Boolean);
/** A Wikidata time ("+2017-08-00T00:00:00Z", precision 9 year, 10 month) as year and month. */
function wdTime(v) {
  const m = /^([+-]?\d{1,6})-(\d\d)-(\d\d)/.exec(v?.time ?? '');
  if (!m) return null;
  const year = Number(m[1]), month = Number(m[2]);
  return { year, month: Number(v.precision) >= 10 && month >= 1 && month <= 12 ? month : null };
}
async function entities(list) {
  const out = {};
  for (let i = 0; i < list.length; i += 50) {
    const b = await polite(`${WD}?${qs({ action: 'wbgetentities', ids: list.slice(i, i + 50).join('|'), props: 'labels|aliases|claims|sitelinks', sitefilter: 'enwiki', languages: 'en' })}`);
    Object.assign(out, b.entities ?? {});
  }
  return out;
}
const label = (e) => e?.labels?.en?.value ?? '';
/** The model's item: a search hit named like it (label or alias) that is a car model (a maker or brand, not a company,
 *  a disambiguation page or a work). */
async function resolveModel(make, model) {
  const want = norm(`${make} ${model}`);
  const b = await polite(`${WD}?${qs({ action: 'wbsearchentities', search: `${make} ${model}`, language: 'en', uselang: 'en', type: 'item', limit: '10' })}`);
  const named = (b.search ?? []).filter((h) => norm(h.label) === want || norm(h.match?.text) === want || (h.aliases ?? []).some((x) => norm(x) === want) || norm(h.label) === norm(model));
  if (!named.length) return null;
  const ents = await entities(named.slice(0, 5).map((h) => h.id));
  for (const h of named.slice(0, 5)) {
    const e = ents[h.id];
    if (!e || ids(e, 'P31').some((q) => NOT_A_CAR.has(q))) continue;
    if (ids(e, 'P176').length || ids(e, 'P1716').length || ids(e, 'P31').some((q) => ['Q3231690', 'Q59773381', 'Q29048322', 'Q1420'].includes(q))) return { id: h.id, label: label(e) || h.label, entity: e };
  }
  return null;
}
const GEN_WORD = /^(\(|[a-z]{1,3}\d|mk|mark|[ivx]+\b|\d+(st|nd|rd|th)\b|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|generation|gen\b|\d{4})/i;
const genOf = (id, e) => {
  const st = wdTime(claim(e, 'P571')[0]) ?? wdTime(claim(e, 'P580')[0]);
  const en = wdTime(claim(e, 'P2669')[0]) ?? wdTime(claim(e, 'P582')[0]) ?? wdTime(claim(e, 'P576')[0]);
  const img = claim(e, 'P18')[0];
  return { id, label: label(e) || id, start: st?.year ?? null, startMonth: st?.month ?? null, end: en?.year ?? null, image: img ? `File:${String(img).replace(/_/g, ' ')}` : null, category: claim(e, 'P373')[0] ?? null };
};
/** The model and its generations: the items that are part of the series of the model, a subclass of it or a part of it,
 *  named like it and followed by a generation word ("Toyota Camry (XV70)"), never another car ("Toyota Camry Solara") or
 *  a race version. */
async function generations(model) {
  const q = model.id;
  const b = await polite(`${WD}?${qs({ action: 'query', list: 'search', srsearch: `haswbstatement:P179=${q}|P279=${q}|P361=${q}|P31=${q}`, srnamespace: '0', srlimit: '50' })}`);
  // also the model's own parts (P527) and, one step out, what each generation follows and is followed by (P155, P156)
  let hits = (b.query?.search ?? []).map((x) => x.title);
  // the combined search found nothing: each statement on its own
  if (!hits.length) for (const pr of ['P179', 'P279']) {
    const b2 = await polite(`${WD}?${qs({ action: 'query', list: 'search', srsearch: `haswbstatement:${pr}=${q}`, srnamespace: '0', srlimit: '50' })}`);
    hits = hits.concat((b2.query?.search ?? []).map((x) => x.title));
  }
  diag.push(`${model.label} ${q}: search ${hits.length}, parts ${ids(model.entity, 'P527').length}`);
  const found = [...new Set([...hits, ...ids(model.entity, 'P527')])].filter((t) => /^Q\d+$/.test(t) && t !== q);
  const ents = found.length ? await entities(found) : {};
  const more = [...new Set(found.flatMap((id) => [...ids(ents[id], 'P155'), ...ids(ents[id], 'P156')]))].filter((id) => id !== q && !found.includes(id));
  if (more.length) { Object.assign(ents, await entities(more.slice(0, 50))); found.push(...more.slice(0, 50)); }
  const self = genOf(q, model.entity);
  const name = self.label || model.label;
  const prefix = norm(name);
  const gens = found.map((id) => genOf(id, ents[id])).filter((g) => {
    if (!norm(g.label).startsWith(prefix)) return false;
    const at = g.label.toLowerCase().indexOf(name.toLowerCase());
    const rest = at >= 0 ? g.label.slice(at + name.length).trim() : '';
    return (!rest || GEN_WORD.test(rest)) && !/nascar|race|racing|rally|concept|police|taxi|electric conversion/i.test(g.label);
  });
  return { self, gens };
}

// ---------------------------------------------------------------- Wikipedia: the generations and their model years
async function wikitext(title) {
  if (!title) return null;
  const b = await polite(`${WP}?${qs({ action: 'parse', page: title, prop: 'wikitext', redirects: '1' })}`);
  return typeof b?.parse?.wikitext === 'string' ? b.parse.wikitext : null;
}
/** The model's generations from its English Wikipedia article (the Wikidata item's sitelink), each completed from its
 *  own article ({{Main|...}}) when the main article gives no years or image (at most 8 articles a model). */
async function wikipediaGenerations(model, t) {
  const title = model.entity?.sitelinks?.enwiki?.title ?? `${t.make_name} ${t.model_name}`;
  const wt = await wikitext(title);
  if (!wt) return [];
  let gens = parseGenerations(wt);
  // a model with one generation so far has no generation sections: the article's own infobox is that generation
  if (!gens.length) {
    const a = articleYears(wt);
    if (a && (a.myFrom || a.start)) gens = [{ id: model.id, label: model.label, code: null, main: null, ...a }];
  }
  let fetched = 0;
  for (const g of gens) {
    if (!g.main || fetched >= 8 || (g.myFrom && g.image)) continue;
    // only generations that can reach the catalog's years
    if (firstModelYear(g) !== null && (g.myTo ?? g.end ?? 9999) < (t.first_year ?? 0) - 1) continue;
    fetched++;
    const a = articleYears((await wikitext(g.main)) ?? '');
    if (!a) continue;
    // the generation's own article is the more precise: its years replace the heading's
    if (firstModelYear(g) === null || (!g.myFrom && (a.myFrom || a.start))) Object.assign(g, { start: a.start, startMonth: a.startMonth, end: a.end, myFrom: a.myFrom, myTo: a.myTo, current: a.current });
    g.image ??= a.image;
  }
  return gens.map((g) => ({ ...g, label: /^(the )?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|[A-Z]{1,4}\d)/i.test(g.label) ? `${model.label} ${g.label}` : g.label }));
}
async function subcategories(cat) {
  if (!cat) return [];
  const b = await polite(`${API}?${qs({ action: 'query', list: 'categorymembers', cmtitle: `Category:${cat.replace(/^Category:/i, '')}`, cmtype: 'subcat', cmlimit: '200' })}`);
  return (b.query?.categorymembers ?? []).map((x) => x.title);
}
/** Files of the model's categories by model year ("Category:2019 Toyota RAV4"): the photo is of that model year. */
async function yearCategoryFiles(names, years) {
  const cats = [...new Set(years.flatMap((y) => names.map((n) => `"${y} ${n}"`.replace(/ /g, '_'))))].slice(0, 6);
  if (!cats.length) return [];
  const b = await polite(`${API}?${qs({ action: 'query', generator: 'search', gsrsearch: `incategory:${cats.join('|')} filetype:bitmap`, gsrnamespace: '6', gsrlimit: '30', ...II })}`);
  return candidates(b.query?.pages);
}
async function searchFiles(q, limit = 20) {
  const b = await polite(`${API}?${qs({ action: 'query', generator: 'search', gsrsearch: q, gsrnamespace: '6', gsrlimit: String(limit), ...II })}`);
  return candidates(b.query?.pages);
}

// ---------------------------------------------------------------- Openverse: a second source (CC0, PDM, BY, BY-SA)
let openverseOff = !!process.env.NO_OPENVERSE;
const PROVIDER = { flickr: 'Flickr', wikimedia: 'Wikimedia Commons', geographorguk: 'Geograph', nappy: 'nappy', rawpixel: 'rawpixel', stocksnap: 'StockSnap' };
async function openverse(q) {
  if (openverseOff) return [];
  try {
    const b = await polite(`${OV}/images/?${new URLSearchParams({ q, license: 'cc0,pdm,by,by-sa', page_size: '20', mature: 'false', filter_dead: 'true' })}`, { tries: 1 });
    return (b.results ?? []).filter((x) => x.source !== 'wikimedia' && x.url && x.foreign_landing_url && x.width && x.height).map((x) => ({
      title: `${x.title ?? ''} [openverse ${x.id}]`, width: x.width, height: x.height, mime: /png$/i.test(x.filetype ?? '') ? 'image/png' : 'image/jpeg',
      meta: openverseMeta(x.license, x.license_version, x.creator), thumb: x.url, thumbWidth: x.width, page: x.foreign_landing_url.replace(/^http:/, 'https:'), verifyAt: x.foreign_landing_url, sha1: null,
      openverse: { license: x.license, version: x.license_version, where: `${PROVIDER[x.source] ?? PROVIDER[x.provider] ?? String(x.source ?? x.provider ?? 'Openverse')} via Openverse`, creatorUrl: x.creator_url ?? null }
    }));
  } catch (e) {
    // a refusal (no key, the day's limit): Openverse is left out for the rest of the run
    openverseOff = true; diag.push(`openverse off: ${e.message}`);
    return [];
  }
}
/** An Openverse hit is used only when its source page shows the same licence. */
async function verifiedAtSource(c) {
  try {
    const html = (await polite(c.verifyAt ?? c.page, { json: false, tries: 1 })).toString('utf8');
    return sourceShowsLicence(html, c.openverse.license, c.openverse.version);
  } catch { return false; }
}
/** The best candidate, an Openverse one only once its source page confirms the licence. */
async function bestOf(pool, ctx) {
  for (let i = 0; i < 4; i++) {
    const b = pickBest(pool, ctx);
    if (!b || !b.c.openverse || b.c.verified) return b;
    if (await verifiedAtSource(b.c)) { b.c.verified = true; return b; }
    ctx.rejected = [...(ctx.rejected ?? []), b.c.title];
  }
  return null;
}

// ---------------------------------------------------------------- one model
const STOP = 80;
async function chooseFor(t, rejectedBy = new Map()) {
  const r = { make: t.make, model: t.model, wikidata: null, rows: [], note: '', gens: 0, ranges: [] };
  let hit;
  try { hit = await resolveModel(t.make_name, t.model_name); } catch (e) {
    // Wikidata behind (maxlag): carry on with the English Wikipedia article of that name (it follows redirects)
    if (!/maxlag/.test(e.message)) throw e;
    hit = { id: null, label: `${t.make_name} ${t.model_name}`, entity: null };
    diag.push(`${t.make}/${t.model}: Wikidata behind, Wikipedia by name`);
  }
  if (!hit) { r.note = 'not found on Wikidata'; return r; }
  r.wikidata = hit.id;
  const first = t.first_year ?? 1980, lastY = t.last_year ?? new Date().getUTCFullYear() + 1;
  const self = genOf(hit.id, hit.entity);
  // generations: Wikipedia's article first (model years), Wikidata's items when the article gives none
  let gens = await wikipediaGenerations(hit, t);
  let source = 'Wikipedia';
  if (!generationRanges(gens, first, lastY).length && hit.id) { gens = (await generations(hit)).gens; source = 'Wikidata'; }
  const ranges = generationRanges(gens, first, lastY);
  r.gens = ranges.length;
  r.ranges = ranges.map((g) => [g.from, g.to]);
  const modelCat = self.category ?? `${hit.label}`;
  const subcats = ranges.length ? await subcategories(modelCat) : [];
  const names = [...new Set([hit.label, `${t.make_name} ${t.model_name}`])];
  const slots = ranges.length ? ranges.map((g) => ({ g, from: g.from, to: g.to })) : [{ g: self, from: null, to: null }];
  const curated = [...new Set([...slots.map((s) => s.g.image), self.image].filter(Boolean))];
  const info = new Map(candidates(curated.length ? await imageInfo(curated) : []).map((c) => [c.title, c]));
  for (const s of slots) {
    if (Date.now() - T0 > BUDGET_MS) break;
    const key = s.from ?? 0;
    // a photo of the model in general is recent: from the 12 model years before the catalog's newest
    const ctx = { make: t.make_name, model: t.model_name, yearFrom: s.from, yearTo: s.to, rejected: [...(rejectedBy.get(key) ?? [])], minYear: s.from ? null : lastY - 12 };
    const pool = [];
    const add = async (fn) => {
      if (best && best.score >= STOP) return;
      // one source failing leaves the others; Wikimedia being behind (maxlag) stops the model, to be taken again
      try { pool.push(...await fn()); } catch (e) { if (/maxlag/.test(e.message)) throw e; diag.push(`${t.make}/${t.model}: ${e.message}`); }
      best = await bestOf(pool, ctx);
    };
    let best = null;
    if (s.g.image && info.get(s.g.image)) pool.push({ ...info.get(s.g.image), wikidata: true });
    best = await bestOf(pool, ctx);
    const cat = s.from ? (categoryFor(s.g, subcats) ?? s.g.category ?? null) : modelCat;
    if (cat) await add(() => categoryFiles(cat, true));
    if (s.from) await add(() => yearCategoryFiles(names, [s.from + 1, s.from, s.from + 2].filter((y) => y <= s.to)));
    if (cat) await add(() => categoryFiles(cat, false));
    await add(() => searchFiles(`intitle:"${hit.label}" ${s.from ? `${Math.min(s.from + 1, s.to)} ` : ''}filetype:bitmap`));
    if (s.g.wikidata || (source === 'Wikidata' && /^Q\d+$/.test(s.g.id))) await add(() => searchFiles(`haswbstatement:P180=${s.g.wikidata ?? s.g.id}`));
    await add(() => openverse(`${t.make_name} ${t.model_name}${s.from ? ` ${Math.min(s.from + 1, s.to)}` : ''}`));
    if (!best) continue;
    r.rows.push(rowOf(best, s, cat));
  }
  diag.push(`${t.make}/${t.model}: ${source} ${ranges.length} generations, ${r.rows.length} photos`);
  r.note = `${ranges.length} generation${ranges.length === 1 ? '' : 's'} in the catalog's years (${source}), ${r.rows.length} photo${r.rows.length === 1 ? '' : 's'}`;
  return r;
}
function rowOf(best, s, cat) {
  const c = best.c, lic = licenceOk(c.meta);
  const ov = c.openverse;
  return {
    year_from: s.from, year_to: s.to, generation: s.g.label ?? null, wikidata: /^Q\d+$/.test(s.g.wikidata ?? s.g.id ?? '') ? (s.g.wikidata ?? s.g.id) : null, category: cat ?? null,
    file_title: c.title, source_url: c.page ?? `https://commons.wikimedia.org/wiki/${encodeURI(c.title.replace(/ /g, '_'))}`, source_name: ov ? ov.where : 'Wikimedia Commons',
    width: c.width, height: c.height, author: plainAuthor(c.meta.Artist) || 'Unknown author', author_url: ov ? (/^https:\/\//.test(ov.creatorUrl ?? '') ? ov.creatorUrl : null) : authorUrl(c.meta.Artist),
    licence: lic.licence, licence_url: lic.licenceUrl, sha1: c.sha1 ?? null, score: best.score, thumb: c.thumb, thumb_width: c.thumbWidth
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
/** A row as saved: without the download's address. */
const stripThumb = (x) => Object.fromEntries(Object.entries(x).filter(([k]) => k !== 'thumb' && k !== 'thumb_width'));
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
    return { make: seg(mk), model: seg(md), make_name: mk, model_name: md, first_year: Number(opt('first-year', '2010')), last_year: new Date().getUTCFullYear() + 1, existing: [] };
  }).filter((t) => !MODELS.length || MODELS.includes(`${t.make}/${t.model}`));
}

// ---------------------------------------------------------------- main
const run = { started: new Date().toISOString(), mode: WRITE ? 'write' : 'dry', targets: TARGETS, models: 0, found: 0, photos: 0, stored: 0, failed: 0, missing: [], picks: [], generic: [], pending: 0, errors: [],
  // model years from 2015 (the years the popular list indexes) covered by a photo of their own generation, by the next
  // generation a year off (near), by a photo of the model only (model), or not at all
  coverage: { models: 0, models_generation: 0, models_any: 0, years: 0, exact: 0, near: 0, model: 0, none: 0, without_generation: [] } };
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

const targets = (TARGETS === 'db' ? ((await one(`select app.stock_photo_targets(${lit({ limit: LIMIT, models: MODELS })})`)) ?? []) : popularTargets().slice(0, LIMIT))
  .filter((_, i) => i % SHARDS === SHARD);
out(`targets: ${targets.length} models (${TARGETS})`);
// the place and service pages' generic photos (a few per kind of page)
if (flag('generic') && SHARD === 0) {
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
      const old = await one(`select app.stock_photo_save_generic(${lit({ slot: s.slot, run_id: runId, rows: rows.filter((r) => !r.failed).map(stripThumb) })})`);
      await removeFiles((old ?? []).flatMap((o) => (o.sizes ?? []).map((w) => `${o.path}-${w}.webp`)));
    }
    run.generic.push({ slot: s.slot, files: rows.map((r) => `${r.file_title.replace(/^File:/, '')} (${r.licence}, ${r.author.slice(0, 30)})`) });
    out(`generic ${s.slot}: ${rows.length}`);
  }
}


/** One model: choose, (write) store and save, count its coverage. Throws on a failure (the caller records it). */
async function processTarget(t) {
  {
    const rejected = new Map((t.existing ?? []).map((e) => [e.year_from ?? 0, e.rejected_files ?? []]));
    const r = await chooseFor(t, rejected);
    if (r.wikidata) run.found++;
    if (!r.rows.length) run.missing.push(`${t.make_name} ${t.model_name}`);
    run.photos += r.rows.length;
    {
      const cv = run.coverage, gensRows = r.rows.filter((x) => x.year_from);
      cv.models++;
      if (gensRows.length) cv.models_generation++; else cv.without_generation.push(`${t.make_name} ${t.model_name}`);
      if (r.rows.length) cv.models_any++;
      for (let y = Math.max(2015, t.first_year ?? 2015); y <= (t.last_year ?? new Date().getUTCFullYear() + 1); y++) {
        // only the model years the model was sold in, by its generations (all years when none is known); the catalog's
        // own years do the same in production
        if (r.ranges.length && !r.ranges.some(([a, b]) => y >= a && y <= b)) continue;
        cv.years++;
        if (gensRows.some((x) => y >= x.year_from && y <= x.year_to)) cv.exact++;
        else if (gensRows.some((x) => y >= x.year_from - 1 && y <= x.year_to + 1)) cv.near++;
        else if (r.rows.length) cv.model++;
        else cv.none++;
      }
    }
    if (WRITE) {
      const have = new Map((t.existing ?? []).map((e) => [`${e.year_from ?? 0}`, e]));
      for (const row of r.rows) {
        const e = have.get(`${row.year_from ?? 0}`);
        // the same file already stored, or a row an Admin chose or hid: kept as it is
        if (e && (e.picked_by === 'admin' || e.status === 'hidden' || (e.file_title === row.file_title && e.path))) { Object.assign(row, { keep: true }); continue; }
        try { await store(`${seg(t.make)}/${seg(t.model)}`, row); run.stored++; } catch (e2) { run.errors.push(`${t.make}/${t.model} ${row.file_title}: ${e2.message}`); row.failed = String(e2.message).slice(0, 200); run.failed++; }
      }
      const old = await one(`select app.stock_photo_save(${lit({ make: t.make, model: t.model, wikidata: r.wikidata, note: r.note, run_id: runId,
        rows: r.rows.filter((x) => !x.failed).map(stripThumb) })})`);
      await removeFiles((old ?? []).flatMap((o) => (o.sizes ?? []).map((w) => `${o.path}-${w}.webp`)));
    } else if (SAMPLES > 0 && run.picks.length < SAMPLES && r.rows[0]) {
      const buf = await polite(r.rows[0].thumb, { json: false });
      const sized = await convert(buf);
      out(`sample ${t.make}/${t.model}: ${sized.map((s) => `${s.width}x${s.height} ${Math.round(s.data.length / 1024)} KB`).join(', ')}`);
    }
    for (const row of r.rows) run.picks.push({ m: `${t.make}/${t.model}`, y: row.year_from ? `${row.year_from}-${row.year_to}` : '', g: row.generation, f: row.file_title.replace(/^File:/, ''),
      w: row.width, h: row.height, l: row.licence, a: row.author.slice(0, 40), s: row.score, src: row.source_name });
    out(`${t.make}/${t.model}: ${r.note}`);
  }
}

const retry = [];
for (const t of targets) {
  if (Date.now() - T0 > BUDGET_MS) { out(`time budget reached after ${run.models} models`); break; }
  run.models++;
  try { await processTarget(t); } catch (e) {
    // Wikimedia's servers were behind (maxlag): the model is taken again at the end of the run
    if (/maxlag/.test(e.message)) retry.push(t); else { run.errors.push(`${t.make}/${t.model}: ${e.message}`); run.failed++; }
    out(`${t.make}/${t.model}: error ${e.message}`);
  }
}
for (const t of retry) {
  if (Date.now() - T0 > BUDGET_MS) { run.errors.push(`${t.make}/${t.model}: maxlag, left for the next run`); run.failed++; continue; }
  try { await processTarget(t); } catch (e) { run.errors.push(`${t.make}/${t.model}: ${e.message}`); run.failed++; }
}

run.finished = new Date().toISOString();
run.diag = diag;
if (process.env.OFFLINE_DEBUG) console.error(diag.join("\n"));
run.http = stats;
if (WRITE) await one(`select app.stock_photo_run_finish(${lit({ id: runId, counts: { models: run.models, found: run.found, photos: run.photos, stored: run.stored, failed: run.failed, pending: run.pending,
  requests: stats.requests, megabytes: Math.round(stats.bytes / 1048576) }, errors: run.errors.slice(0, 50) })})`);
if (MANIFEST) writeFileSync(MANIFEST, JSON.stringify(run, null, 1));
out(`coverage: ${JSON.stringify({ ...run.coverage, without_generation: run.coverage.without_generation.length })}`);
out(`done: ${run.models} models, ${run.found} on Wikidata, ${run.photos} photos chosen, ${run.stored} stored, ${run.failed} failed, ${stats.requests} requests (${stats.retries} retried), ${Math.round(stats.bytes / 1048576)} MB downloaded`);
if (run.missing.length) out(`missing: ${run.missing.join(', ')}`);
