#!/usr/bin/env node
// The photographed rooms of the listing showroom (migration 2400; features/listing/photo-room.ts). Finds real dealership or
// studio interiors on Wikimedia Commons licensed for commercial use with credit at most (CC0, public domain, CC BY; never
// BY-SA, NC or ND), picks the best few (landscape, large, no people or cars named in the title), and with --write
// downloads the 2400 px thumbnail once, crops it to 1800 x 1200 JPEG without metadata, stores it in the public bucket
// (vehicle-public, site/backdrop/photos/<slug>.jpg) and saves the row in showroom_backgrounds with the author, licence and
// source. Rooms already stored are kept (fetched once); --replace fetches again.
//
// Polite to Wikimedia as scripts/seo-photos/run.mjs: one request at a time, a second apart, a User-Agent with a contact,
// maxlag=5, Retry-After obeyed, the standard thumbnail (never the original).
//
//   node scripts/showroom-photos.mjs [--count 3] [--write] [--replace] [--manifest FILE]
//     --write     store and save (STORAGE_URL, SERVICE_KEY, and SQL_API_URL or SUPABASE_PROJECT_REF + SUPABASE_ACCESS_TOKEN)
//     --files T   only these Commons file titles (comma separated; "File:..."), e.g. rooms an Admin picked
// The floor line of each room starts at 0.82 of the height; an Admin can correct it (showroom_backgrounds.floor_line).
import { writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const args = process.argv.slice(2);
const opt = (k, d = null) => { const i = args.indexOf(`--${k}`); return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : d; };
const flag = (k) => args.includes(`--${k}`);
const WRITE = flag('write'), REPLACE = flag('replace');
const COUNT = Math.max(1, Math.min(6, Number(opt('count', '3'))));
const MANIFEST = opt('manifest');
const FILES = (opt('files', '') || '').split(',').map((s) => s.trim()).filter(Boolean);
const API = process.env.WM_COMMONS_API ?? 'https://commons.wikimedia.org/w/api.php';
const UA = 'CarmaCarsStockPhotos/1.0 (https://carmacars.ca; hello@carmacars.ca) node';
const GAP_MS = Number(process.env.WM_GAP_MS ?? 1000);

// ---------------------------------------------------------------- polite HTTP
let last = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function polite(url, { json = true, tries = 5 } = {}) {
  for (let i = 0; ; i++) {
    const wait = last + GAP_MS - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    let r;
    try { r = await fetch(url, { headers: { 'user-agent': UA, 'api-user-agent': UA }, signal: AbortSignal.timeout(60_000) }); }
    catch (e) { if (i >= tries) throw e; await sleep(5000 * (i + 1)); continue; }
    if ([429, 502, 503, 504].includes(r.status)) {
      if (i >= tries) throw new Error(`${r.status} from ${new URL(url).host}`);
      const ra = Number(r.headers.get('retry-after'));
      await sleep(Math.min(Number.isFinite(ra) && ra > 0 ? ra * 1000 : 10_000 * (i + 1), 120_000)); continue;
    }
    if (!r.ok) throw new Error(`${r.status} from ${url.slice(0, 160)}`);
    if (!json) return Buffer.from(await r.arrayBuffer());
    const body = await r.json();
    if (body?.error?.code === 'maxlag') { if (i >= tries + 3) throw new Error('maxlag'); await sleep(5000); continue; }
    return body;
  }
}
const qs = (o) => new URLSearchParams({ format: 'json', formatversion: '2', maxlag: '5', ...o }).toString();
const II = { prop: 'imageinfo', iiprop: 'url|size|mime|extmetadata', iiurlwidth: '2400',
  iiextmetadatafilter: 'LicenseShortName|LicenseUrl|Artist|ImageDescription|Categories|ObjectName', iiextmetadatalanguage: 'en' };

// ---------------------------------------------------------------- licence and choice (pure, exported for the tests)
const strip = (h) => String(h ?? '').replace(/<[^>]*>/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/\s+/g, ' ').trim();
/** The licence as showroom_backgrounds keeps it, or null when it is not allowed (BY-SA, NC, ND, unknown). */
export function licenceOf(short) {
  const s = String(short ?? '').trim();
  if (/^CC0( 1\.0)?$/i.test(s)) return 'CC0';
  if (/^(public domain|pd|pd-[\w-]+)$/i.test(s)) return 'Public domain';
  const m = /^CC BY ([0-9.]+)$/i.exec(s);
  return m ? `CC BY ${m[1]}` : null;
}
const SEARCHES = ['car showroom interior', 'car dealership showroom interior', 'empty car showroom', 'automobile showroom interior', 'photo studio cyclorama empty'];
const AVOID = /\b(people|person|crowd|visitors|man|woman|girl|boy|staff|logo|sign|exterior|facade|night|street|parking|museum|motor show|auto show|expo|exhibition)\b/i;
/** A score for a room: landscape, large, interior words in the title, no people or exhibitions; null when unusable. */
export function scoreRoom(f) {
  if (!f || f.mime !== 'image/jpeg' || !f.width || !f.height || f.width < 2000 || f.width / f.height < 1.3 || f.width / f.height > 2.2) return null;
  if (!licenceOf(f.licence)) return null;
  const t = `${f.title} ${f.description ?? ''}`;
  if (AVOID.test(t)) return null;
  let s = Math.min(3, f.width / 2000);
  if (/showroom|dealership|studio/i.test(t)) s += 2;
  if (/interior|inside|empty/i.test(t)) s += 1;
  if (!/^CC BY/.test(licenceOf(f.licence))) s += 0.5;   // no credit needed: a little better
  return Math.round(s * 100) / 100;
}
export const slugOf = (title) => String(title).replace(/^File:/i, '').replace(/\.[a-z]+$/i, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'room';

async function candidates() {
  const titles = new Set(FILES);
  if (!titles.size) {
    for (const q of SEARCHES) {
      const b = await polite(`${API}?${qs({ action: 'query', list: 'search', srsearch: q, srnamespace: '6', srlimit: '40' })}`);
      for (const r of b?.query?.search ?? []) titles.add(r.title);
    }
  }
  const out = [];
  const list = [...titles];
  for (let i = 0; i < list.length; i += 40) {
    const b = await polite(`${API}?${qs({ action: 'query', titles: list.slice(i, i + 40).join('|'), ...II })}`);
    for (const p of b?.query?.pages ?? []) {
      const ii = p.imageinfo?.[0]; if (!ii) continue;
      const m = ii.extmetadata ?? {}, v = (k) => m[k]?.value ?? null;
      const artist = strip(v('Artist')), href = /href="([^"]+)"/.exec(v('Artist') ?? '')?.[1] ?? null;
      out.push({ title: p.title, width: ii.width, height: ii.height, mime: ii.mime, thumb: ii.thumburl ?? ii.url, source: ii.descriptionurl,
        licence: strip(v('LicenseShortName')), licence_url: v('LicenseUrl'), author: artist || 'Unknown author', author_url: href ? (href.startsWith('//') ? `https:${href}` : href) : null,
        description: strip(v('ImageDescription')).slice(0, 300) });
    }
  }
  return out.map((f) => ({ ...f, score: scoreRoom(f) })).filter((f) => f.score !== null).sort((a, b) => b.score - a.score);
}

// ---------------------------------------------------------------- storage and the database (as scripts/seo-photos/run.mjs)
const STORAGE = process.env.STORAGE_URL, KEY = process.env.SERVICE_KEY;
async function put(path, data) {
  const r = await fetch(`${STORAGE}/object/vehicle-public/${path}`, { method: 'POST', headers: { authorization: `Bearer ${KEY}`, apikey: KEY, 'content-type': 'image/jpeg',
    'cache-control': 'max-age=31536000', 'x-upsert': 'true' }, body: data, signal: AbortSignal.timeout(120_000) });
  if (!r.ok) throw new Error(`storage ${r.status}: ${(await r.text()).slice(0, 200)}`);
}
const lit = (o) => { const j = JSON.stringify(o); const t = j.includes('$sr$') ? `$p${randomBytes(4).toString('hex')}$` : '$sr$'; return `${t}${j}${t}::jsonb`; };
async function sql(query) {
  const api = process.env.SQL_API_URL, ref = process.env.SUPABASE_PROJECT_REF, token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!api && (!ref || !token)) throw new Error('SQL_API_URL, or SUPABASE_PROJECT_REF and SUPABASE_ACCESS_TOKEN, are needed');
  const r = await fetch(api ?? `https://api.supabase.com/v1/projects/${ref}/database/query`, { method: 'POST',
    headers: { ...(api ? {} : { authorization: `Bearer ${token}` }), 'content-type': 'application/json' }, body: JSON.stringify({ query }), signal: AbortSignal.timeout(120_000) });
  const text = await r.text();
  if (!r.ok) throw new Error(`SQL failed (${r.status}): ${text.slice(0, 400)}`);
  const rows = JSON.parse(text);
  return Array.isArray(rows) ? rows : rows?.result ?? [];
}

// ---------------------------------------------------------------- main
if (import.meta.url === `file://${process.argv[1]}`) {
  const run = { mode: WRITE ? 'write' : 'dry', found: 0, picked: [], stored: 0, errors: [] };
  if (WRITE) {
    if (!STORAGE || !KEY) throw new Error('STORAGE_URL and SERVICE_KEY are needed to write');
    const have = Number(Object.values((await sql('select count(*) as n from showroom_backgrounds where active'))[0] ?? {})[0] ?? 0);
    if (have >= COUNT && !REPLACE) { console.log(`showroom-photos: ${have} rooms stored already, nothing to do`); process.exit(0); }
  }
  const all = await candidates();
  run.found = all.length;
  const sharp = WRITE ? (await import('sharp')).default : null;
  for (const [k, f] of all.slice(0, COUNT).entries()) {
    const row = { slug: slugOf(f.title), title: f.title.replace(/^File:/, '').slice(0, 300), source_url: f.source, author: f.author.slice(0, 300), author_url: f.author_url,
      licence: licenceOf(f.licence), licence_url: f.licence_url, sort: (k + 1) * 10, score: f.score };
    run.picked.push(row);
    if (!WRITE) continue;
    try {
      const buf = await polite(f.thumb, { json: false });
      // the frame's size, centred; no metadata (sharp strips EXIF, GPS, XMP by default)
      const jpg = await sharp(buf).rotate().resize(1800, 1200, { fit: 'cover', position: 'centre' }).jpeg({ quality: 86, mozjpeg: true }).toBuffer();
      const path = `site/backdrop/photos/${row.slug}.jpg`;
      await put(path, jpg);
      await sql(`insert into showroom_backgrounds (slug, title, storage_path, source_url, author, author_url, licence, licence_url, sort, fetched_at)
        select r.slug, r.title, '${path}', r.source_url, r.author, r.author_url, r.licence, r.licence_url, r.sort, now() from jsonb_populate_record(null::showroom_backgrounds, ${lit(row)}) r
        on conflict (slug) do update set title = excluded.title, storage_path = excluded.storage_path, source_url = excluded.source_url, author = excluded.author,
          author_url = excluded.author_url, licence = excluded.licence, licence_url = excluded.licence_url, fetched_at = now()`);
      run.stored++;
    } catch (e) { run.errors.push(`${f.title}: ${e.message}`.slice(0, 300)); }
  }
  if (MANIFEST) writeFileSync(MANIFEST, JSON.stringify(run, null, 2));
  console.log(`showroom-photos: ${run.mode}, ${run.found} usable rooms found, ${run.picked.length} picked, ${run.stored} stored, ${run.errors.length} errors`);
  for (const p of run.picked) console.log(`  ${p.slug} (${p.licence}, ${p.author}) ${p.source_url}`);
  for (const e of run.errors) console.log(`  error: ${e}`);
  if (WRITE && run.picked.length && !run.stored) process.exit(1);
}
