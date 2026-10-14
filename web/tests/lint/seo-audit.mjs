// SEO audit of the running production build (docs/blueprint/14-seo.md), every public page and car page:
// unique titles and descriptions, the canonical on the site's own address, Open Graph and Twitter cards with
// an image, JSON-LD that parses with the nodes each page should carry (business, car, breadcrumbs) and no
// self-serving ratings, one h1 and no skipped heading levels, alt text on every image, a sitemap with every
// indexable page and nothing else, robots.txt keeping out the private paths (and those paths sending
// noindex), links from home and the fleet to every car and model hub, a real 404, and redirects for cars
// that left the fleet. Fails on any problem; writes reports/seo.json.
//   BASE_URL=http://localhost:3000 node tests/lint/seo-audit.mjs [--site https://carmacars.ca]
import fs from 'node:fs';

const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const i = process.argv.indexOf('--site');
const problems = []; const report = { base: BASE, pages: {} };
const bad = (where, what) => problems.push(`${where}: ${what}`);

const get = async (p, opt = {}) => { const r = await fetch(BASE + p, { redirect: 'manual', ...opt }); return { status: r.status, headers: r.headers, body: r.headers.get('content-type')?.includes('text') || r.headers.get('content-type')?.includes('xml') ? await r.text() : '' }; };
const attr = (tag, name) => new RegExp(`\\b${name}="([^"]*)"`).exec(tag)?.[1]?.replace(/&amp;/g, '&');
const meta = (html, key) => { for (const m of html.matchAll(/<meta\b[^>]*>/g)) { const t = m[0]; if (attr(t, 'name') === key || attr(t, 'property') === key) return attr(t, 'content') ?? null; } return null; };
const decode = (s) => s?.replace(/&amp;/g, '&').replace(/&#x27;|&#39;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>') ?? s;

// ------------------------------------------------------------------ robots and sitemap
const robots = (await get('/robots.txt')).body;
const SITE = process.argv[i + 1] && i > 0 ? process.argv[i + 1] : /Sitemap: (\S+)\/sitemap\.xml/.exec(robots)?.[1] ?? BASE;
const disallow = [...robots.matchAll(/^Disallow: (\S+)/gm)].map((m) => m[1]);
const PRIVATE = ['/account', '/owner', '/investor', '/admin', '/va', '/field', '/api/', '/book', '/sign-in', '/create-account', '/reset-password', '/update-password', '/two-step', '/unsubscribe', '/files/', '/d/', '/sign/', '/r/'];
for (const p of PRIVATE) if (!disallow.some((d) => p.startsWith(d))) bad('robots.txt', `does not disallow ${p}`);
if (!/^Sitemap: https?:\/\/\S+\/sitemap\.xml$/m.test(robots)) bad('robots.txt', 'no sitemap line');
for (const p of ['/account', '/owner', '/admin', '/va', '/field', '/investor', '/book/x', '/two-step', '/unsubscribe']) {
  const r = await get(p);
  const tag = r.headers.get('x-robots-tag') ?? '';
  const metaNo = /<meta name="robots" content="[^"]*noindex/.test(r.body);
  if (!/noindex/.test(tag) && !metaNo && r.status < 300) bad(p, 'private path without noindex');
}
const sm = (await get('/sitemap.xml')).body;
const smUrls = [...sm.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
const paths = smUrls.map((u) => new URL(u).pathname);
report.sitemap = paths.length;
for (const u of smUrls) if (!u.startsWith(SITE)) bad('sitemap', `${u} is not on ${SITE}`);
if (new Set(paths).size !== paths.length) bad('sitemap', 'duplicate entries');

// ------------------------------------------------------------------ pages
const cars = new Set(paths.filter((p) => /^\/cars\/[^/]+$/.test(p)));
const hubs = new Set(paths.filter((p) => /^\/rent\/[^/]+$/.test(p)));
const titles = new Map(); const descs = new Map();
const extra = ['/investors'];
for (const p of [...new Set([...paths, ...extra])]) {
  const r = await get(p);
  const rec = { status: r.status };
  report.pages[p] = rec;
  if (r.status !== 200) { bad(p, `HTTP ${r.status}${r.headers.get('location') ? ' to ' + r.headers.get('location') : ''}`); continue; }
  const h = r.body;
  const title = decode(/<title>([^<]*)<\/title>/.exec(h)?.[1] ?? '');
  const desc = decode(meta(h, 'description'));
  const canon = /<link rel="canonical" href="([^"]+)"/.exec(h)?.[1];
  const robotsMeta = meta(h, 'robots');
  Object.assign(rec, { title, desc, canon, robots: robotsMeta });
  const indexable = !/noindex/.test(robotsMeta ?? '');
  if (!indexable) { if (paths.includes(p)) bad(p, 'in the sitemap but noindex'); continue; }
  if (!title) bad(p, 'no title'); else { if (title.length > 70) bad(p, `title ${title.length} characters (over 70): ${title}`); titles.set(title, [...(titles.get(title) ?? []), p]); }
  if (!desc) bad(p, 'no meta description'); else { if (desc.length < 70 || desc.length > 170) bad(p, `description ${desc.length} characters (70 to 170)`); descs.set(desc, [...(descs.get(desc) ?? []), p]); }
  if (canon !== SITE + (p === '/' ? '' : p) && canon !== SITE + p) bad(p, `canonical ${canon} (want ${SITE}${p === '/' ? '' : p})`);
  for (const k of ['og:title', 'og:description', 'og:url', 'og:image', 'og:site_name', 'twitter:card', 'twitter:image', 'twitter:title']) if (!meta(h, k)) bad(p, `no ${k}`);
  const og = meta(h, 'og:image');
  if (og && !/^https?:\/\//.test(og)) bad(p, `og:image is not absolute: ${og}`);
  // JSON-LD
  const ld = [...h.matchAll(/<script\b[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const nodes = [];
  for (const s of ld) { try { const j = JSON.parse(s); nodes.push(...(j['@graph'] ?? [j])); } catch (e) { bad(p, 'JSON-LD does not parse: ' + String(e).slice(0, 80)); } }
  const types = nodes.flatMap((n) => [].concat(n['@type'] ?? []));
  rec.ld = types;
  const txt = JSON.stringify(nodes);
  if (/aggregateRating|"review"/i.test(txt)) bad(p, 'JSON-LD carries ratings or reviews of our own business or cars (self-serving)');
  if (/18122211|Canada Inc/i.test(h)) bad(p, 'numbered company name in the page');
  if (p === '/' && !types.includes('AutoRental')) bad(p, 'no AutoRental (business) node');
  if (p !== '/' && !types.includes('BreadcrumbList')) bad(p, 'no BreadcrumbList');
  if (cars.has(p)) {
    if (!types.includes('Car')) bad(p, 'no Car node');
    const car = nodes.find((n) => [].concat(n['@type']).includes('Car'));
    if (car && !car.offers) bad(p, 'Car node without offers');
    if (car && !(car.image?.length)) bad(p, 'Car node without images');
  }
  // headings, images
  const hs = [...h.matchAll(/<h([1-6])\b/g)].map((m) => Number(m[1]));
  if (hs.filter((x) => x === 1).length !== 1) bad(p, `${hs.filter((x) => x === 1).length} h1 elements`);
  for (let k = 1; k < hs.length; k++) if (hs[k] > hs[k - 1] + 1) { bad(p, `heading jumps from h${hs[k - 1]} to h${hs[k]}`); break; }
  for (const m of h.matchAll(/<img\b[^>]*>/g)) if (!/\balt="/.test(m[0])) bad(p, `image without alt: ${m[0].slice(0, 100)}`);
  if (/[—–]/.test(h.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, ''))) bad(p, 'long dash in the page');
  rec.links = [...h.matchAll(/<a\b[^>]*\bhref="([^"#?]+)/g)].map((m) => m[1].replace(SITE, '').replace(BASE, ''));
}
for (const [t, ps] of titles) if (ps.length > 1) bad('titles', `"${t}" on ${ps.join(', ')}`);
for (const [d, ps] of descs) if (ps.length > 1) bad('descriptions', `"${d.slice(0, 60)}..." on ${ps.join(', ')}`);

// ------------------------------------------------------------------ internal linking
const from = (p) => new Set(report.pages[p]?.links ?? []);
const fleetLinks = new Set([...from('/cars'), ...from('/')]);
for (const c of cars) if (!fleetLinks.has(c)) bad('linking', `${c} has no link from home or /cars`);
for (const hb of hubs) {
  const linked = [...Object.values(report.pages)].some((pg) => pg.links?.includes(hb));
  if (!linked) bad('linking', `${hb} has no link from any public page`);
  if (![...cars].some((c) => report.pages[c]?.links?.includes(hb)) && !fleetLinks.has(hb)) bad('linking', `${hb} has no link from home, /cars or a car page`);
}
// pages linked from public pages that are not in the sitemap but should be
for (const pg of Object.values(report.pages)) for (const l of pg.links ?? []) {
  if (/^\/(cars|rent)\/[^/]+$/.test(l) && !paths.includes(l)) { const r = report.pages[l] ?? { status: (await get(l)).status }; if (r.status === 200) bad('sitemap', `${l} is linked but missing`); }
}

// ------------------------------------------------------------------ 404 and removed cars
const nf = await get('/no-such-page-' + Date.now());
if (nf.status !== 404) bad('404', `unknown path answers ${nf.status}`);
if (!/noindex/.test(nf.body)) bad('404', 'the not-found page is not noindex');
const nc = await get('/cars/no-such-car-' + Date.now());
if (nc.status !== 404) bad('404', `unknown car answers ${nc.status}`);
// cars that left the fleet (listing_redirects, docs/blueprint/14-seo.md section 11): from the local database
// when there is one, or SEO_REDIRECTS="/cars/old>/rent/hub,/cars/gone>410"
let moved = (process.env.SEO_REDIRECTS ?? '').split(',').filter(Boolean).map((x) => x.split('>'));
if (!moved.length && !process.env.NO_DB) {
  try {
    const { default: postgres } = await import('postgres');
    const db = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, connect_timeout: 3, onnotice: () => {} });
    moved = (await db`select from_path, coalesce(to_path, '') to_path, status_code from listing_redirects order by created_at desc limit 5`).map((r) => [r.from_path, r.status_code === 410 ? '410' : r.to_path]);
    await db.end();
  } catch { /* no local database: nothing to check */ }
}
report.redirects = moved.length;
for (const [src, want] of moved) {
  const r = await get(src);
  if (want === '410') { if (![404, 410].includes(r.status)) bad('redirects', `${src} answers ${r.status} (want 410 or 404)`); continue; }
  if (![301, 308].includes(r.status) || !r.headers.get('location')?.endsWith(want)) bad('redirects', `${src} answers ${r.status} to ${r.headers.get('location')} (want 301 to ${want})`);
}

report.problems = problems;
fs.mkdirSync('reports', { recursive: true });
fs.writeFileSync('reports/seo.json', JSON.stringify(report, null, 2));
console.log(`seo: ${Object.keys(report.pages).length} pages (${cars.size} cars, ${hubs.size} model hubs), sitemap ${paths.length} entries`);
if (problems.length) { console.log(problems.join('\n')); console.log(`seo: FAILED, ${problems.length} problems`); process.exit(1); }
console.log('seo: 0 problems');
