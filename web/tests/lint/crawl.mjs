// Crawls the running site from / and returns every internal page with its HTML.
export async function crawl(base, extra = []) {
  const seen = new Map(); const queue = ['/', ...extra];
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
      if (!seen.has(p) && !queue.includes(p)) queue.push(p);
    }
  }
  return seen;
}
