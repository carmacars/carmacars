// Crawls the running site from / and returns every internal page with its HTML. The place pages of migration 0095
// (/car-rental/<term>/<place>, /buy/..., /detailing/..., /body-shop/...) are a mesh of every place and term: a sample
// is crawled (PLACE_SAMPLE per term, PLACE_CAP in all) and the rest is listed in `skipped` (the same template).
export const PLACE_HUB = /^\/(car-rental|buy|detailing|body-shop)\/[a-z0-9-]+\/[a-z0-9-]+$/;
const PLACE_SAMPLE = 3; const PLACE_CAP = 150;
export async function crawl(base, extra = []) {
  const seen = new Map(); const queue = ['/', ...extra];
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
