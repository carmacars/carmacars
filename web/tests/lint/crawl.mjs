// Crawls the running site from / and returns every internal page with its HTML.
// The city and colour pages and the /buy twins (0092) are tens of thousands of pages of a few templates: SAMPLE of each
// shape (depth, and colour or not) are fetched and checked; the others are recorded as sampled (not fetched), so a
// link to them is not reported as uncrawled. Their addresses are checked by the SEO audit's sitemap pass.
const SAMPLE = Number(process.env.CRAWL_SAMPLE ?? 6);
const family = (p) => { const m = /^\/(cars|buy)((?:\/[^/?]+)+)/.exec(p); if (!m || (m[1] === 'cars' && m[2].split('/').length <= 5)) return null; return `${m[1]}:${m[2].split('/').length}:${m[2].includes('/colour/')}`; };
export async function crawl(base, extra = []) {
  const seen = new Map(); const queue = ['/', ...extra]; const shapes = new Map();
  while (queue.length) {
    const path = queue.shift();
    const key = path.split('#')[0];
    if (seen.has(key)) continue;
    const f = family(key);
    if (f) { const n = shapes.get(f) ?? 0; if (n >= SAMPLE) { seen.set(key, { status: 200, html: '', sampled: true }); continue; } shapes.set(f, n + 1); }
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
      if (!seen.has(p) && !queue.includes(p)) queue.push(p);
    }
  }
  return seen;
}
