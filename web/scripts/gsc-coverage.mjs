// The index coverage report (release 28, B7; migration 0564): a sample of the site's addresses inspected with Search
// Console's URL Inspection API, counted by coverage state (indexed, crawled not indexed, discovered not indexed, other)
// and by kind of page, to see whether the indexed count moves. The gsc workflow runs it after the sitemaps step.
//
//   AT=<token> SITE=sc-domain:carmacars.ca INSPECT=150 OUT=coverage.json node --experimental-strip-types web/scripts/gsc-coverage.mjs
//
// The sample: a third from the priority sitemap (the pages that matter most), the rest spread over the place and vehicle
// files, so every run looks at a different slice. The API allows 2,000 inspections a day per property; the workflow's
// eight runs a day at 150 stay under it. Never prints the token.
import fs from 'node:fs';
import { coverageBucket, pageKind, pickSample } from '../src/features/seo/coverage.ts';

const AT = process.env.AT ?? '';
const SITE = process.env.SITE ?? '';
const BASE = (process.env.BASE ?? 'https://carmacars.ca').replace(/\/$/, '');
const N = Math.min(Number(process.env.INSPECT ?? 150), 250);
const UA = 'CarmaCars crawl check (gsc workflow)';
const locs = (xml) => [...String(xml).matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => m[1]);
const get = async (u) => { try { const r = await fetch(u, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(60_000) }); return r.ok ? await r.text() : ''; } catch { return ''; } };

if (!AT || !SITE || N <= 0) { console.log('::notice title=coverage::nothing to inspect (no token, no property or INSPECT=0)'); process.exit(0); }
const index = locs(await get(`${BASE}/sitemap.xml`));
const priorityFiles = index.filter((u) => /sitemap-priority/.test(u));
const otherFiles = index.filter((u) => !/sitemap-priority/.test(u));
const priority = [];
for (const f of priorityFiles.slice(0, 3)) priority.push(...locs(await get(f)).filter((u) => !u.endsWith('.xml')));
// the long tail: a few files chosen by the hour, so each run looks at another slice
const hour = Math.floor(Date.now() / 3_600_000);
const tail = [];
for (let i = 0; i < Math.min(4, otherFiles.length); i++) {
  const f = otherFiles[(hour * 7 + i * 13) % otherFiles.length];
  const inner = locs(await get(f));
  // an index file lists more files: take one of them
  if (inner.length && inner.every((u) => u.endsWith('.xml'))) tail.push(...locs(await get(inner[(hour + i) % inner.length])));
  else tail.push(...inner);
}
const sample = pickSample(priority, tail.filter((u) => !u.endsWith('.xml')), N, hour);

const byState = {}, byKind = {};
let errors = 0, done = 0;
for (const url of sample) {
  try {
    const r = await fetch('https://searchconsole.googleapis.com/v1/urlInspection/index:inspect', {
      method: 'POST', headers: { authorization: `Bearer ${AT}`, 'content-type': 'application/json' },
      body: JSON.stringify({ inspectionUrl: url, siteUrl: SITE }), signal: AbortSignal.timeout(30_000)
    });
    if (r.status === 429) { console.log('::warning title=coverage::the inspection quota is used for today; stopping'); break; }
    if (!r.ok) { errors++; continue; }
    const j = await r.json();
    const state = j?.inspectionResult?.indexStatusResult?.coverageState ?? 'Unknown';
    byState[state] = (byState[state] ?? 0) + 1;
    const k = pageKind(new URL(url).pathname);
    byKind[k] ??= { indexed: 0, crawled: 0, discovered: 0, other: 0 };
    byKind[k][coverageBucket(state)]++;
    done++;
  } catch { errors++; }
}
const out = { inspected: done, by_state: byState, by_kind: byKind, errors };
if (process.env.OUT) fs.writeFileSync(process.env.OUT, JSON.stringify(out));
const pct = (n) => (done ? `${Math.round((n / done) * 100)}%` : '0%');
const indexed = (byState['Submitted and indexed'] ?? 0) + (byState['Indexed, not submitted in sitemap'] ?? 0);
console.log(`::notice title=coverage::${done} inspected: ${pct(indexed)} indexed, ${pct(byState['Crawled - currently not indexed'] ?? 0)} crawled not indexed, ${pct(byState['Discovered - currently not indexed'] ?? 0)} discovered not indexed (${errors} errors)`);
if (process.env.GITHUB_STEP_SUMMARY) {
  const rows = Object.entries(byKind).map(([k, v]) => `| ${k} | ${v.indexed} | ${v.crawled} | ${v.discovered} | ${v.other} |`).join('\n');
  fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n### Index coverage (sample of ${done})\n\n| Kind | Indexed | Crawled, not indexed | Discovered, not indexed | Other |\n|---|---|---|---|---|\n${rows}\n`);
}
