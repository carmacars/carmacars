// Crawls the running site from / and returns every internal page with its HTML. The place pages of migration 0095
// (/car-rental/<term>/<place>, /buy/..., /detailing/..., /body-shop/...) are a mesh of every place and term: a sample
// is crawled (PLACE_SAMPLE per term, PLACE_CAP in all) and the rest is listed in `skipped` (the same template).
export const PLACE_HUB = /^\/(car-rental|buy|detailing|body-shop)\/[a-z0-9-]+\/[a-z0-9-]+$/;
const PLACE_SAMPLE = 3; const PLACE_CAP = 150;
// The vehicle pages' city and colour pages and their twins (0092, /cars/.../<trim>/<place>, /buy/..., /t/<term>/...) are
// millions of pages of a few templates: SAMPLE of each shape (depth, and colour or not; one per term tree) are fetched;
// the others are recorded as sampled (not fetched), so a link to them is not reported as uncrawled. Their addresses are
// checked by the SEO audit's sitemap pass.
const SAMPLE = Number(process.env.CRAWL_SAMPLE ?? 6);
const family = (p) => { if (PLACE_HUB.test(p)) return null; const m = /^\/(cars|buy|t)((?:\/[^/?]+)+)/.exec(p); if (!m || (m[1] === 'cars' && m[2].split('/').length <= 5)) return null; return m[1] === 't' ? `t:${m[2].split('/')[1]}:${m[2].split('/').length}` : `${m[1]}:${m[2].split('/').length}:${m[2].includes('/colour/')}`; };
export async function crawl(base, extra = []) {
  const seen = new Map(); const queue = ['/', ...extra]; const shapes = new Map();
  const perTerm = new Map(); let hubs = 0; const skipped = new Set();
  const sampled = (p) => {
    if (!PLACE_HUB.test(p)) return true;
    const k = p.split('/').slice(0, 3).join('/');
    if (hubs >= PLACE_CAP || (perTerm.get(k) ?? 0) >= PLACE_SAMPLE) { skipped.add(p); return false; }
    perTerm.set(k, (perTerm.get(k) ?? 0) + 1); hubs++; return true;
  };
  while (queue.length) {
    const path = queue.shift();
    const key = path.split('#')[0];
    if (seen.has(key)) continue;
    const f = family(key);
    if (f) { const n = shapes.get(f) ?? 0; if (n >= (f.startsWith('t:') ? 1 : SAMPLE)) { seen.set(key, { status: 200, html: '', sampled: true }); continue; } shapes.set(f, n + 1); }
    const res = await fetch(base + key, { redirect: 'manual' });
    const html = res.headers.get('content-type')?.includes('text/html') ? await res.text() : '';
    seen.set(key, { status: res.status, html, location: res.headers.get('location') });
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) { const l = new URL(res.headers.get('location'), base); if (l.origin === new URL(base).origin) queue.push(l.pathname + l.search); }
    for (const m of html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)) {
      const h = m[1].replace(/&amp;/g, '&');
      if (/^(mailto:|tel:|https?:)/.test(h) && !h.startsWith(base)) continue;
      if (h.startsWith('#')) continue;
      const u = new URL(h, base + key);
      if (u.origin !== new URL(base).origin) continue;
      const p = u.pathname + u.search;
      if (!seen.has(p) && !queue.includes(p) && !skipped.has(p) && sampled(p)) queue.push(p);
    }
  }
  seen.skipped = skipped;
  return seen;
}
