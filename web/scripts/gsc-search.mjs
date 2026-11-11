// Search Console's Search Analytics by day for the investor deck (migration 1507; the gsc workflow, .github/workflows/gsc.yml).
//
//   node web/scripts/gsc-search.mjs
//
// Environment: AT (an OAuth access token for the Search Console API), SITE (the property: sc-domain:carmacars.ca), DAYS
// (how far back, 90), OUT (a JSON file of [{day, clicks, impressions, ctr, position}] for app.gsc_search_store). Never
// prints the token. Google's last ~3 days are partial; they are read again on the next runs.
import fs from 'node:fs';

const AT = process.env.AT ?? '';
const SITE = process.env.SITE ?? '';
const DAYS = Math.min(480, Math.max(7, Number(process.env.DAYS ?? 90)));
const OUT = process.env.OUT ?? '';
if (!AT || !SITE || !OUT) { console.log('::warning title=gsc search::AT, SITE and OUT are needed'); process.exit(0); }
const iso = (d) => d.toISOString().slice(0, 10);
const end = new Date(); end.setUTCDate(end.getUTCDate() - 1);
const start = new Date(end); start.setUTCDate(start.getUTCDate() - DAYS);
const r = await fetch(`https://www.googleapis.com/webmasters/v3/sites/${encodeURIComponent(SITE)}/searchAnalytics/query`, {
  method: 'POST', headers: { authorization: `Bearer ${AT}`, 'content-type': 'application/json' },
  body: JSON.stringify({ startDate: iso(start), endDate: iso(end), dimensions: ['date'], rowLimit: 1000, dataState: 'all' }), signal: AbortSignal.timeout(60_000)
}).catch((e) => ({ ok: false, status: 0, text: async () => String(e) }));
if (!r.ok) { console.log(`::warning title=gsc search::Search Analytics answered ${r.status}: ${(await r.text()).slice(0, 200).replace(/\s+/g, ' ')}`); process.exit(0); }
const j = await r.json();
const rows = (j.rows ?? []).map((x) => ({ day: x.keys?.[0], clicks: Math.round(x.clicks ?? 0), impressions: Math.round(x.impressions ?? 0), ctr: x.ctr ?? null, position: x.position ?? null }))
  .filter((x) => /^\d{4}-\d{2}-\d{2}$/.test(x.day ?? ''));
fs.writeFileSync(OUT, JSON.stringify(rows));
const sum = (k) => rows.reduce((a, x) => a + x[k], 0);
console.log(`::notice title=gsc search::${rows.length} days, ${sum('clicks')} clicks and ${sum('impressions')} impressions since ${iso(start)}`);
