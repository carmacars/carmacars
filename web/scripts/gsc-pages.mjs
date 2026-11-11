// Search Analytics by query and by page for the SEO page (migration 1860; the gsc workflow, .github/workflows/gsc.yml).
//
//   AT=<token> SITE=sc-domain:carmacars.ca OUT=gsc-pages.json node web/scripts/gsc-pages.mjs
//
// Environment: AT (an OAuth access token), SITE (the property), OUT (a JSON file {window_end, rows: [{kind, key, clicks,
// impressions, ctr, position}]} for app.gsc_pages_store), ROWS (rows per kind, 5,000 by default; the API returns the most
// clicked first). The window is the last 28 days that Google has settled (it ends 3 days ago). Pages are stored as paths.
// A failure is a warning, never a failed run. Never prints the token.
import fs from 'node:fs';

const AT = process.env.AT ?? '';
const SITE = process.env.SITE ?? '';
const OUT = process.env.OUT ?? '';
const ROWS = Math.min(25_000, Math.max(100, Number(process.env.ROWS ?? 5000)));
if (!AT || !SITE || !OUT) { console.log('::warning title=gsc pages::AT, SITE and OUT are needed'); process.exit(0); }
const iso = (d) => d.toISOString().slice(0, 10);
const end = new Date(); end.setUTCDate(end.getUTCDate() - 3);
const start = new Date(end); start.setUTCDate(start.getUTCDate() - 27);

/** A page address as a site path (https://carmacars.ca/cars/x -> /cars/x); null when it is not on the site or has a query. */
export function pagePath(u) {
  try { const x = new URL(u); return x.search ? null : (x.pathname.length > 1 ? x.pathname.replace(/\/$/, '') : x.pathname); } catch { return null; }
}

async function query(dimension) {
  const r = await fetch(`https://www.googleapis.com/webmasters/v3/sites/${encodeURIComponent(SITE)}/searchAnalytics/query`, {
    method: 'POST', headers: { authorization: `Bearer ${AT}`, 'content-type': 'application/json' },
    body: JSON.stringify({ startDate: iso(start), endDate: iso(end), dimensions: [dimension], rowLimit: ROWS, dataState: 'final' }), signal: AbortSignal.timeout(90_000)
  }).catch((e) => ({ ok: false, status: 0, text: async () => String(e) }));
  if (!r.ok) { console.log(`::warning title=gsc pages::Search Analytics (${dimension}) answered ${r.status}: ${(await r.text()).slice(0, 200).replace(/\s+/g, ' ')}`); return null; }
  return (await r.json()).rows ?? [];
}

const rows = [];
for (const [kind, dim] of [['query', 'query'], ['page', 'page']]) {
  const got = await query(dim);
  if (!got) continue;
  for (const x of got) {
    const key = kind === 'page' ? pagePath(x.keys?.[0] ?? '') : String(x.keys?.[0] ?? '').slice(0, 300);
    if (!key) continue;
    rows.push({ kind, key, clicks: Math.round(x.clicks ?? 0), impressions: Math.round(x.impressions ?? 0), ctr: x.ctr ?? null, position: x.position ?? null });
  }
}
if (rows.length) fs.writeFileSync(OUT, JSON.stringify({ window_end: iso(end), rows }));
console.log(`::notice title=gsc pages::${rows.filter((x) => x.kind === 'query').length} queries and ${rows.filter((x) => x.kind === 'page').length} pages for ${iso(start)} to ${iso(end)}`);
