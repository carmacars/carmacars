// SEO audit of the running production build (docs/blueprint/14-seo.md), every public page and car page:
// unique titles and descriptions, the canonical on the site's own address, Open Graph and Twitter cards with
// an image, JSON-LD that parses with the nodes each page should carry (business, car, breadcrumbs) and no
// self-serving ratings, one h1 and no skipped heading levels, alt text on every image, a sitemap with every
// indexable page and nothing else, robots.txt keeping out the private paths (and those paths sending
// noindex), links from home and the fleet to every car and model hub, a real 404, and redirects for cars
// that left the fleet. Since 0061 also: the sitemap index and its parts (lastmod, car photos), hreflang en-CA, the
// WebSite node with its search, the business address, landing pages (FAQ, list of cars, noindex below the threshold,
// never in the sitemap then), guides (Article with author, publisher and dates), ratings only on a car with its
// reviews shown, the IndexNow key file and the footer's location links. Fails on any problem; writes reports/seo.json.
//   BASE_URL=http://localhost:3000 node tests/lint/seo-audit.mjs [--site https://carmacars.ca]
import fs from 'node:fs';

const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const i = process.argv.indexOf('--site');
const problems = []; const report = { base: BASE, pages: {} };
const bad = (where, what) => problems.push(`${where}: ${what}`);

// one page at a time, 60 seconds each, one more try: a page that never answers is a problem named with its address
// (it used to stop the whole audit with an undici headers timeout and no address)
const get = async (p, opt = {}) => {
  for (let i = 0; ; i++) {
    try {
      const r = await fetch(BASE + p, { redirect: 'manual', signal: AbortSignal.timeout(60_000), ...opt });
      return { status: r.status, headers: r.headers, body: r.headers.get('content-type')?.includes('text') || r.headers.get('content-type')?.includes('xml') ? await r.text() : '' };
    } catch (e) {
      if (i < 1) continue;
      console.log(`seo: no answer from ${p}: ${e?.cause?.code ?? e?.name ?? e}`);
      return { status: 0, headers: new Headers(), body: '', error: String(e?.cause?.code ?? e?.name ?? e) };
    }
  }
};
const attr = (tag, name) => new RegExp(`\\b${name}="([^"]*)"`).exec(tag)?.[1]?.replace(/&amp;/g, '&');
const meta = (html, key) => { for (const m of html.matchAll(/<meta\b[^>]*>/g)) { const t = m[0]; if (attr(t, 'name') === key || attr(t, 'property') === key) return attr(t, 'content') ?? null; } return null; };
const decode = (s) => s?.replace(/&amp;/g, '&').replace(/&#x27;|&#39;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>') ?? s;

// ------------------------------------------------------------------ robots and sitemap
const robots = (await get('/robots.txt')).body;
const SITE = process.argv[i + 1] && i > 0 ? process.argv[i + 1] : /Sitemap: (\S+)\/sitemap\.xml/.exec(robots)?.[1] ?? BASE;
const disallow = [...robots.matchAll(/^Disallow: (\S+)/gm)].map((m) => m[1]);
const PRIVATE = ['/choose-portal', '/account', '/owner', '/investor', '/admin', '/va', '/field', '/api/', '/book', '/sign-in', '/create-account', '/reset-password', '/update-password', '/two-step', '/unsubscribe', '/files/', '/d/', '/sign/', '/r/'];
for (const p of PRIVATE) if (!disallow.some((d) => p.startsWith(d))) bad('robots.txt', `does not disallow ${p}`);
if (!/^Sitemap: https?:\/\/\S+\/sitemap\.xml$/m.test(robots)) bad('robots.txt', 'no sitemap line');
for (const p of ['/account', '/owner', '/admin', '/va', '/field', '/investor', '/book/x', '/two-step', '/unsubscribe']) {
  const r = await get(p);
  const tag = r.headers.get('x-robots-tag') ?? '';
  const metaNo = /<meta name="robots" content="[^"]*noindex/.test(r.body);
  if (!/noindex/.test(tag) && !metaNo && r.status < 300) bad(p, 'private path without noindex');
}
const sm = (await get('/sitemap.xml')).body;
const smUrls = [];
if (/<sitemapindex/.test(sm)) {
  const parts = [...sm.matchAll(/<sitemap><loc>([^<]+)<\/loc>(?:<lastmod>([^<]+)<\/lastmod>)?<\/sitemap>/g)];
  report.sitemapParts = parts.map((m) => m[1]);
  if (parts.length < 4) bad('sitemap', `index lists ${parts.length} parts (want pages, cars, landing, guides)`);
  // the term trees (/t/<term>, 0092) mirror the renting tree file for file: every file name is checked against it, and of
  // each term's tree the makes and the first place and colour file are read (the rest are the same addresses under
  // another prefix); every other file is read whole
  const names = parts.map(([, loc]) => new URL(loc).pathname.replace(/^\/sitemap-vehicles\/|\.xml$/g, ''));
  const rentFiles = new Set(names.filter((n) => !/^(buy-|t-)/.test(n) && /^(makes|tiers-\d+|[a-z0-9-]+-(models|years|trims)(-\d+)?)$/.test(n)));
  const termTrees = new Map();
  const splitT = (n) => { for (let i = n.indexOf('-', 2); i > 0; i = n.indexOf('-', i + 1)) if (rentFiles.has(n.slice(i + 1))) return [n.slice(2, i), n.slice(i + 1)]; return null; };
  for (const n of names.filter((x) => x.startsWith('t-'))) { const m = splitT(n); if (!m) bad('sitemap', `${n} has no renting twin`); else termTrees.set(m[0], [...(termTrees.get(m[0]) ?? []), m[1]]); }
  report.termTrees = termTrees.size;
  for (const [, loc, lastmod] of parts) {
    if (lastmod && Number.isNaN(Date.parse(lastmod))) bad('sitemap', `${loc} has an unreadable lastmod`);
    const tn = /\/sitemap-vehicles\/(t-[a-z0-9-]+)\.xml$/.exec(loc);
    const tb = tn ? splitT(tn[1])?.[1] : null;
    if (tn && tb !== 'makes' && tb !== 'tiers-1') continue;
    const part = await get(new URL(loc).pathname);
    if (part.status !== 200 || !/<urlset/.test(part.body)) { bad('sitemap', `${loc} answers ${part.status}`); continue; }
    // a car entry carries its photos (image sitemap) when the car has real photos; a car that shows sample photos has
    // none to list (0070 lists cars before their photos), so only those whose page shows real photos are checked
    if (/sitemap-cars/.test(loc)) {
      for (const [, blk] of [...part.body.matchAll(/<url>([\s\S]*?)<\/url>/g)].slice(0, 40)) {
        if (/<image:image>/.test(blk)) continue;
        const u = blk.match(/<loc>([^<]+)<\/loc>/)?.[1];
        if (!u) continue;
        const pg = await get(new URL(u).pathname);
        if (pg.status === 200 && !/Representative photo|Sample photo/.test(pg.body)) bad('sitemap', `${new URL(u).pathname} has real photos but no image entry (image sitemap)`);
      }
    }
    for (const m of part.body.matchAll(/<lastmod>([^<]+)<\/lastmod>/g)) if (Number.isNaN(Date.parse(m[1]))) bad('sitemap', `unreadable lastmod ${m[1]} in ${loc}`);
    smUrls.push(...[...part.body.matchAll(/<url><loc>([^<]+)<\/loc>/g)].map((m) => m[1].replace(/&amp;/g, '&')));
  }
} else {
  bad('sitemap', '/sitemap.xml is not a sitemap index');
  smUrls.push(...[...sm.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]));
}
const paths = smUrls.map((u) => new URL(u).pathname);
// The city and colour pages and the /buy twins (0092) are tens of thousands of addresses of a few templates: every
// address is checked in the sitemaps (on the site, no duplicates, lastmod), and an even sample of each kind is audited
// as a page (title, description, canonical, JSON-LD, uniqueness among the sample and with every other page).
const heavy = (p) => /^\/(buy|t)\//.test(p) || /^\/cars\/[^/]+\/[^/]+\/\d{4}\/[^/]+\/.+/.test(p);
const SAMPLE = Number(process.env.SEO_SAMPLE ?? 60);
const sampleOf = (xs) => xs.length <= SAMPLE ? xs : Array.from({ length: SAMPLE }, (_, i) => xs[Math.floor((i * xs.length) / SAMPLE)]);
const kinds = new Map();
for (const p of paths.filter(heavy)) { const k = `${p.split('/')[1]}:${p.split('/').length}:${p.includes('/colour/')}`; kinds.set(k, [...(kinds.get(k) ?? []), p]); }
const auditPaths = [...paths.filter((p) => !heavy(p)), ...[...kinds.values()].flatMap(sampleOf)];
report.sampled = Object.fromEntries([...kinds].map(([k, v]) => [k, { addresses: v.length, audited: Math.min(v.length, SAMPLE) }]));
if (![...kinds.keys()].some((k) => k.startsWith('cars:'))) bad('sitemap', 'no city or colour pages in the sitemaps (the owner indexes them by default)');
if (![...kinds.keys()].some((k) => k.startsWith('buy:'))) bad('sitemap', 'no /buy pages in the sitemaps (the owner indexes them by default)');
if (![...kinds.keys()].some((k) => k.startsWith('t:'))) bad('sitemap', 'no search term pages (/t/...) in the sitemaps (the owner indexes them by default)');
report.sitemap = paths.length;
for (const u of smUrls) if (!u.startsWith(SITE)) bad('sitemap', `${u} is not on ${SITE}`);
if (new Set(paths).size !== paths.length) bad('sitemap', 'duplicate entries');

// ------------------------------------------------------------------ pages
// Car and model pages: those in the sitemap and every one the fleet page links to. A sample car (vehicles.is_sample,
// 0035) and a model page of samples only are noindex and out of the sitemap; their content is checked all the same.
const fleetHtml = (await get('/cars')).body;
const fleetCarLinks = [...fleetHtml.matchAll(/href="(\/(?:cars|rent)\/[^"#?/]+)"/g)].map((m) => m[1]);
// the vehicle pages (0092): /cars/<make> shares the car pages' shape; they are told apart by their own sitemaps
const vehiclePaths = new Set();
for (const loc of report.sitemapParts ?? []) if (/\/sitemap-vehicles\//.test(loc)) {
  for (const m of (await get(new URL(loc).pathname)).body.matchAll(/<loc>([^<]+)<\/loc>/g)) { const vp = new URL(m[1]).pathname; if (!heavy(vp)) vehiclePaths.add(vp); }
}
const cars = new Set([...paths, ...fleetCarLinks].filter((p) => /^\/cars\/[^/]+$/.test(p) && !vehiclePaths.has(p)));
const hubs = new Set([...paths, ...fleetCarLinks].filter((p) => /^\/rent\/[^/]+$/.test(p)));
// landing pages and guides: those in the sitemap and every one the hubs link to (a use page under the threshold is noindex)
const hubHtml = (await get('/car-rental')).body + (await get('/guides')).body;
const landing = new Set([...paths, ...[...hubHtml.matchAll(/href="(\/car-rental\/[^"#?/]+)"/g)].map((m) => m[1])].filter((p) => /^\/car-rental\/[^/]+$/.test(p)));
const guides = new Set([...paths, ...[...hubHtml.matchAll(/href="(\/guides\/[^"#?/]+)"/g)].map((m) => m[1])].filter((p) => /^\/guides\/[^/]+$/.test(p)));
report.noindex = [];
const titles = new Map(); const descs = new Map(); const bodies = new Map(); const h1s = new Map();
const extra = ['/investors'];
for (const p of [...new Set([...auditPaths, ...extra, ...cars, ...hubs, ...landing, ...guides])]) {
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
  if (!indexable) {
    if (paths.includes(p)) bad(p, 'in the sitemap but noindex');
    // a vehicle page held out of search by the Admin's rules names its parent as canonical (0092); any other noindex page has none
    const parent = p.split('/').slice(0, -1).join('/');
    if (canon && !(/^\/cars\/[^/]+\/[^/]+/.test(p) && canon === SITE + parent)) bad(p, 'noindex page with a canonical link');
    report.noindex.push(p);
    if (!cars.has(p) && !hubs.has(p) && !landing.has(p)) continue;
  }
  if (indexable && !new RegExp(`<link rel="alternate" hrefLang="en-CA" href="${(SITE + (p === '/' ? '' : p)).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`, 'i').test(h)) bad(p, 'no hreflang en-CA alternate');
  if (!title) bad(p, 'no title'); else { if (title.length > 70) bad(p, `title ${title.length} characters (over 70): ${title}`); titles.set(title, [...(titles.get(title) ?? []), p]); }
  if (!desc) bad(p, 'no meta description'); else { if (desc.length < 70 || desc.length > 170) bad(p, `description ${desc.length} characters (70 to 170)`); descs.set(desc, [...(descs.get(desc) ?? []), p]); }
  if (indexable && canon !== SITE + (p === '/' ? '' : p) && canon !== SITE + p) bad(p, `canonical ${canon} (want ${SITE}${p === '/' ? '' : p})`);
  for (const k of ['og:title', 'og:description', 'og:url', 'og:image', 'og:site_name', 'twitter:card', 'twitter:image', 'twitter:title']) if (!meta(h, k)) bad(p, `no ${k}`);
  const og = meta(h, 'og:image');
  if (og && !/^https?:\/\//.test(og)) bad(p, `og:image is not absolute: ${og}`);
  // JSON-LD
  const ld = [...h.matchAll(/<script\b[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const nodes = [];
  for (const s of ld) { try { const j = JSON.parse(s); nodes.push(...(j['@graph'] ?? [j])); } catch (e) { bad(p, 'JSON-LD does not parse: ' + String(e).slice(0, 80)); } }
  const types = nodes.flatMap((n) => [].concat(n['@type'] ?? []));
  rec.ld = types;
  // ratings: never on the business or the site; on a car only with its own reviews shown on the page
  for (const n of nodes) {
    const ty = [].concat(n['@type'] ?? []);
    if (!(n.aggregateRating || n.review)) continue;
    if (!ty.includes('Car')) bad(p, `JSON-LD rating on ${ty.join('/')} (self-serving)`);
    else if (!/id="h-rv"/.test(h) || Number(n.aggregateRating?.reviewCount ?? 0) < 1) bad(p, 'Car rating without the reviews shown on the page');
  }
  if (/18122211|Canada Inc/i.test(h)) bad(p, 'numbered company name in the page');
  if (p === '/' && !types.includes('AutoRental')) bad(p, 'no AutoRental (business) node');
  if (p === '/') {
    const biz = nodes.find((n) => [].concat(n['@type']).includes('AutoRental'));
    if (biz && !(biz.address?.streetAddress && biz.address?.postalCode && biz.telephone)) bad(p, 'business node without the street address, postal code or phone');
    const site = nodes.find((n) => [].concat(n['@type']).includes('WebSite'));
    if (!site?.potentialAction?.target) bad(p, 'no WebSite node with its SearchAction');
  }
  if (!types.includes('WebSite')) bad(p, 'no WebSite node');
  if (landing.has(p)) {
    if (!types.includes('ItemList')) bad(p, 'landing page without the list of its cars');
    if (/id="h-faq"/.test(h) && !types.includes('FAQPage')) bad(p, 'landing page FAQ without FAQPage');
    if (!indexable && paths.includes(p)) bad(p, 'noindex landing page in the sitemap');
  }
  if (guides.has(p)) {
    const art = nodes.find((n) => [].concat(n['@type']).includes('Article'));
    if (!art) bad(p, 'guide without an Article node');
    else for (const k of ['headline', 'datePublished', 'dateModified', 'author', 'publisher', 'image']) if (!art[k]) bad(p, `Article without ${k}`);
  }
  if (p !== '/' && !types.includes('BreadcrumbList')) bad(p, 'no BreadcrumbList');
  if (vehiclePaths.has(p) && p.split('/').length > 3) {
    // a model, year or trim page: its Product/Car node; offers only when real cars of ours match (never an empty offer)
    const car = nodes.find((n) => [].concat(n['@type']).includes('Car'));
    if (!car) bad(p, 'vehicle page without its Car node');
    if (car?.offers && !(Number(car.offers.offerCount) > 0)) bad(p, 'vehicle page with an offer and no car');
    if (!types.includes('FAQPage')) bad(p, 'vehicle page without FAQPage');
  }
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
  // vehicle pages (0092): every one indexed by the owner's decision, so no two may share their main body either
  if (vehiclePaths.has(p) || heavy(p)) {
    const h1 = decode((/<h1\b[^>]*>([\s\S]*?)<\/h1>/.exec(h)?.[1] ?? '').replace(/<[^>]+>/g, '').trim());
    if (h1) h1s.set(h1, [...(h1s.get(h1) ?? []), p]);
    const main = (/<main\b[\s\S]*?<\/main>/.exec(h)?.[0] ?? h).replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    bodies.set(main, [...(bodies.get(main) ?? []), p]);
  }
  rec.links = [...h.matchAll(/<a\b[^>]*\bhref="([^"#?]+)/g)].map((m) => m[1].replace(SITE, '').replace(BASE, ''));
}
for (const [t, ps] of titles) if (ps.length > 1) bad('titles', `"${t}" on ${ps.join(', ')}`);
for (const p of auditPaths.filter(heavy)) {
  const links = new Set(report.pages[p]?.links ?? []);
  if (!report.pages[p] || report.pages[p].status !== 200) continue;
  if (p.startsWith('/buy/') && !links.has('/cars/' + p.slice(5))) bad('linking', `${p} does not link to its rental twin`);
  if (p.startsWith('/cars/') && ![...links].some((l) => p.startsWith(l + '/') && l.split('/').length === 6)) bad('linking', `${p} does not link to its trim page`);
}
for (const [x, ps] of h1s) if (ps.length > 1) bad('h1', `"${x}" on ${ps.join(', ')}`);
for (const [, ps] of bodies) if (ps.length > 1) bad('bodies', `the same main body on ${ps.join(', ')}`);
if (report.sitemapParts && !report.sitemapParts.some((l) => /\/sitemap-vehicles\/makes\.xml$/.test(l))) bad('sitemap', 'index without the vehicle sitemaps (sitemap-vehicles/makes.xml)');
report.vehiclePages = vehiclePaths.size;
for (const [d, ps] of descs) if (ps.length > 1) bad('descriptions', `"${d.slice(0, 60)}..." on ${ps.join(', ')}`);

// ------------------------------------------------------------------ internal linking
const from = (p) => new Set(report.pages[p]?.links ?? []);
const fleetLinks = new Set([...from('/cars'), ...from('/')]);
for (const c of cars) if (!fleetLinks.has(c)) bad('linking', `${c} has no link from home or /cars`);
// vehicle pages: every make from /cars, every other level from its parent page (the tree, up and down)
for (const v of vehiclePaths) {
  const up = v.split('/').slice(0, -1).join('/');
  if (v.split('/').length === 3) { if (!fleetLinks.has(v)) bad('linking', `${v} has no link from home or /cars`); }
  else if (report.pages[up] && !from(up).has(v)) bad('linking', `${v} has no link from ${up}`);
  if (report.pages[v] && v.split('/').length > 3 && !from(v).has(up)) bad('linking', `${v} does not link up to ${up}`);
}
for (const hb of hubs) {
  const linked = [...Object.values(report.pages)].some((pg) => pg.links?.includes(hb));
  if (!linked) bad('linking', `${hb} has no link from any public page`);
  if (![...cars].some((c) => report.pages[c]?.links?.includes(hb)) && !fleetLinks.has(hb)) bad('linking', `${hb} has no link from home, /cars or a car page`);
}
// pages linked from public pages that are not in the sitemap but should be
for (const pg of Object.values(report.pages)) for (const l of pg.links ?? []) {
  if (/^\/(cars|rent)\/[^/]+$/.test(l) && !paths.includes(l) && !report.noindex.includes(l)) {
    const r = await get(l);
    if (r.status !== 200) continue;
    if (/noindex/.test(meta(r.body, 'robots') ?? '')) { report.noindex.push(l); if (/<link rel="canonical"/.test(r.body)) bad(l, 'noindex page with a canonical link'); continue; }
    bad('sitemap', `${l} is linked but missing`);
  }
}

// the footer links every indexable location page; the hub links every indexable landing page
const footer = new Set(report.pages['/']?.links ?? []);
for (const l of landing) if (report.pages[l] && !/noindex/.test(report.pages[l].robots ?? '') && !footer.has(l) && !(report.pages['/car-rental']?.links ?? []).includes(l)) bad('linking', `${l} has no link from the footer or /car-rental`);

// the IndexNow key file at the root (the key from the robots-side database when there is one)
if (!process.env.NO_DB) {
  try {
    const { default: postgres } = await import('postgres');
    const db = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, connect_timeout: 3, onnotice: () => {} });
    const [{ k }] = await db`select indexnow_key k from site_settings limit 1`;
    await db.end();
    const r = await get(`/${k}.txt`);
    if (r.status !== 200 || r.body.trim() !== k) bad('indexnow', `/${k}.txt answers ${r.status}`);
    report.indexnow = 'key file ok';
  } catch { /* no local database */ }
}
if ((await get('/0123456789abcdef0123456789abcdef.txt')).status !== 404) bad('indexnow', 'a wrong key file does not answer 404');

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
console.log(`seo: ${Object.keys(report.pages).length} pages (${cars.size} cars, ${hubs.size} model hubs, ${landing.size} landing pages, ${guides.size} guides), sitemap ${paths.length} entries in ${report.sitemapParts?.length ?? 1} files, ${report.noindex.length} noindex (sample cars, their model pages, landing pages under the threshold)`);
if (problems.length) { console.log(problems.join('\n')); console.log(`seo: FAILED, ${problems.length} problems`); process.exit(1); }
console.log('seo: 0 problems');
