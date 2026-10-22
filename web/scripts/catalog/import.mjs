#!/usr/bin/env node
// The vehicle catalog import (migration 0092; docs/changes/2026-10-21-vehicle-pages.md). Run by the catalog workflow
// (.github/workflows/catalog.yml): GitHub's runners reach fueleconomy.gov and vPIC, the development sandbox cannot.
//
//   node --experimental-strip-types --no-warnings scripts/catalog/import.mjs [options]
//     --csv <file>          the EPA vehicles.csv (default: download https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip)
//     --vpic                also read vPIC's model names for each make and year (NHTSA, public domain)
//     --vpic-json <file>    vPIC's names from a file instead ({make: {year: [names]}}), as the fixture keeps them
//     --sql-out <file>      write the import as SQL (the batches, begin and finish), for a local database or a test
//     --write               apply it to production through the Supabase Management API (SUPABASE_ACCESS_TOKEN,
//                           SUPABASE_PROJECT_REF): only the catalog workflow does this
//     --fixture-out <dir>   write the fixture subset (the EPA rows and vPIC names of FIXTURE_MODELS) for the tests
//     --stats <file>        write the counts (makes, models, years, trims) as JSON
//     --run-url <url>       recorded with the import (the workflow run)
//
// Sources: EPA (US Department of Energy and EPA, fueleconomy.gov: public domain); vPIC (US DOT NHTSA: public domain);
// the Canadian trim names of web/scripts/catalog/canada-trims.txt (compiled by CarmaCars from the makers' Canadian
// lineups; facts, editable in Admin > Settings > Vehicle pages).
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { batches, buildCatalog, CANADA_MAKES, parseCsv, parsePopular, parseTrimList } from '../../src/features/vehicles/normalise.ts';
import { slugify } from '../../src/features/vehicles/units.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
const flag = (k) => argv.includes(k);
const NOW_YEAR = new Date().getUTCFullYear();
const YEARS = [2010, NOW_YEAR + 1];
const UA = { 'user-agent': 'CarmaCars vehicle catalog (+https://carmacars.ca)', accept: 'application/json,text/csv,application/zip,*/*' };

/** The models the committed fixture keeps (the sample cars, the real cars and a few edge cases): make | model | years. */
export const FIXTURE_MODELS = [
  ['Volkswagen', 'Jetta', 2019, 2021], ['Toyota', 'Corolla', 2022, 2024], ['Toyota', 'Camry', 2023, 2023], ['Toyota', 'RAV4', 2023, 2023],
  ['Honda', 'Civic', 2022, 2022], ['Honda', 'CR-V', 2023, 2023], ['Chevrolet', 'Malibu', 2022, 2022], ['Kia', 'Forte', 2021, 2023],
  ['Tesla', 'Model 3', 2023, 2023], ['Ford', 'F150', 2022, 2022], ['Ford', 'Mustang', 2022, 2022], ['Mercedes-Benz', 'C-Class', 2022, 2022],
  ['Cadillac', 'CTS', 2015, 2015], ['Porsche', 'Macan', 2016, 2016], ['Mazda', 'MX-5', 2021, 2021], ['Hyundai', 'Elantra', 2023, 2023]
];

async function get(url, as = 'text') {
  let last;
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(url, { headers: UA, redirect: 'follow', signal: AbortSignal.timeout(120_000) });
      if (!r.ok) throw new Error(`${r.status} ${r.statusText} ${url}`);
      return as === 'bytes' ? new Uint8Array(await r.arrayBuffer()) : as === 'json' ? await r.json() : await r.text();
    } catch (e) { last = e; await new Promise((s) => setTimeout(s, 2000 * (i + 1))); }
  }
  throw last;
}

async function epaCsv() {
  const file = arg('--csv');
  if (file) return readFileSync(file, 'utf8');
  const dir = mkdtempSync(join(tmpdir(), 'epa-'));
  writeFileSync(join(dir, 'vehicles.csv.zip'), await get('https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip', 'bytes'));
  execFileSync('unzip', ['-o', '-q', join(dir, 'vehicles.csv.zip'), '-d', dir]);
  return readFileSync(join(dir, 'vehicles.csv'), 'utf8');
}

/** vPIC's model names: every model of each make (its spelling, "F-150" over EPA's "F150"), and the models of the current
 *  and next model year (coverage EPA does not have yet). About 150 calls, six at a time, within a time budget: vPIC
 *  answering slowly never holds up the import (the catalog is then built from EPA alone). */
async function vpicNames() {
  const out = {};
  const t0 = Date.now(), BUDGET = 8 * 60_000;
  const jobs = [];
  for (const make of [...new Set(Object.values(CANADA_MAKES))]) {
    jobs.push([make, null]);
    for (const y of [YEARS[1] - 1, YEARS[1]]) jobs.push([make, y]);
  }
  let failed = 0, done = 0;
  const one = async (url) => {
    for (let i = 0; i < 2; i++) {
      try {
        const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(30_000) });
        if (r.ok) return await r.json();
      } catch { /* retried once */ }
    }
    throw new Error('vPIC did not answer');
  };
  const work = async () => {
    for (let job = jobs.shift(); job; job = jobs.shift()) {
      if (Date.now() - t0 > BUDGET) { failed++; continue; }
      const [make, y] = job;
      const url = y ? `https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMakeYear/make/${encodeURIComponent(make)}/modelyear/${y}?format=json`
        : `https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMake/${encodeURIComponent(make)}?format=json`;
      try {
        const j = await one(url);
        const names = [...new Set((j.Results ?? []).map((r) => String(r.Model_Name ?? '').trim()).filter(Boolean))];
        // the make's whole list stands for its spellings: filed under year 0, which adds names but no model year
        if (names.length) ((out[slugify(make)] ??= {})[y ?? 0] = names);
        done++;
      } catch { failed++; }
    }
  };
  await Promise.all(Array.from({ length: 6 }, work));
  console.log(`vpic: ${done} calls answered, ${failed} not, ${Math.round((Date.now() - t0) / 1000)} s`);
  return { names: out, failed };
}
const toMap = (o) => new Map(Object.entries(o).map(([m, ys]) => [m, new Map(Object.entries(ys).map(([y, n]) => [Number(y), n]))]));

// ---------------------------------------------------------------- SQL
const tag = () => `$cat${randomBytes(4).toString('hex')}$`;
const lit = (o) => { const t = tag(); return `${t}${JSON.stringify(o)}${t}::jsonb`; };
function statements(catalog, meta) {
  const s = [`select app.vehicle_catalog_import_begin(${lit(meta)})`];
  for (const b of batches(catalog)) s.push(`select app.vehicle_catalog_import_batch(${lit(b)})`);
  s.push(`select app.vehicle_catalog_import_popular(${lit(catalog.popular)})`);
  s.push(`select app.vehicle_catalog_import_finish(${lit({ makes: catalog.makes.map((m) => m.slug) })})`);
  return s;
}

async function management(sql) {
  const ref = process.env.SUPABASE_PROJECT_REF, token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!ref || !token) throw new Error('SUPABASE_PROJECT_REF and SUPABASE_ACCESS_TOKEN are needed to write');
  const r = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ query: sql }), signal: AbortSignal.timeout(300_000)
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`SQL failed (${r.status}): ${text.slice(0, 600)}`);
  return text;
}

// ---------------------------------------------------------------- main
const t0 = Date.now();
const csv = await epaCsv();
console.log(`epa: ${csv.length} bytes in ${Math.round((Date.now() - t0) / 1000)} s`);
const rows = parseCsv(csv);
console.log(`epa: ${rows.length} rows parsed`);
const trimLines = parseTrimList(readFileSync(join(HERE, 'canada-trims.txt'), 'utf8'));
const popular = parsePopular(readFileSync(join(HERE, 'popular.txt'), 'utf8'));
let vpic = null, vpicFailed = 0;
if (arg('--vpic-json')) vpic = JSON.parse(readFileSync(arg('--vpic-json'), 'utf8'));
else if (flag('--vpic')) { const v = await vpicNames(); vpic = v.names; vpicFailed = v.failed; }
const catalog = buildCatalog(rows, { years: YEARS, vpic: vpic ? toMap(vpic) : undefined, trimLines, popular });

const trimCount = catalog.trim_lines.reduce((n, t) => n + t.trims.length * (t.to - t.from + 1), 0);
const stats = {
  epa_rows: rows.length, makes: catalog.makes.length, models: catalog.models.length, model_years: catalog.years.length,
  model_years_with_specs: catalog.years.filter((y) => y.variants.length).length, powertrains: catalog.years.reduce((n, y) => n + y.variants.length, 0),
  trim_lines: catalog.trim_lines.length, trim_lines_unmatched: trimLines.length - catalog.trim_lines.length, trim_pages_upper_bound: trimCount,
  models_two_years: catalog.models.filter((m) => catalog.years.filter((y) => y.make === m.make && y.model === m.slug).length >= 2).length,
  popular: catalog.popular.length, popular_unmatched: popular.length - catalog.popular.length, vpic_failed_calls: vpicFailed, seconds: Math.round((Date.now() - t0) / 1000)
};
const unmatched = [...trimLines.filter((t) => !catalog.trim_lines.some((c) => c.make === t.make && c.from === t.from && c.trims.join() === t.trims.join())).map((t) => `${t.make}/${t.model}`),
  ...popular.filter((p) => !catalog.popular.some((c) => c.make === p.make && slugify(c.model).replace(/-/g, '') === slugify(p.model).replace(/-/g, ''))).map((p) => `popular ${p.make}/${p.model}`)];
console.log(JSON.stringify(stats));
if (unmatched.length) console.log(`not in the catalog: ${[...new Set(unmatched)].join(', ')}`);
if (arg('--stats')) writeFileSync(arg('--stats'), JSON.stringify({ ...stats, unmatched: [...new Set(unmatched)] }, null, 2));

if (arg('--fixture-out')) {
  const dir = arg('--fixture-out');
  mkdirSync(dir, { recursive: true });
  const key = (s) => slugify(s).replace(/-/g, '');
  const keep = rows.map((r) => [r]).filter(([r]) => FIXTURE_MODELS.some(([mk, md, a, b]) => r.make === mk && Number(r.year) >= a && Number(r.year) <= b
    && (key(r.baseModel ?? r.basemodel) === key(md) || key(r.model).startsWith(key(md)))));
  // the fixture keeps only the columns the import reads, so the file stays small
  const cols = ['id', 'year', 'make', 'model', 'baseModel', 'atvType', 'fuelType', 'fuelType1', 'displ', 'cylinders', 'tCharger', 'sCharger', 'drive', 'trany', 'VClass',
    'city08', 'city08U', 'highway08', 'highway08U', 'comb08', 'comb08U', 'combE', 'range', 'rangeA', 'co2TailpipeGpm'];
  const q = (v) => (/[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  const pickCol = (r, c) => r[c] ?? r[Object.keys(r).find((k) => k.toLowerCase() === c.toLowerCase()) ?? ''] ?? '';
  writeFileSync(join(dir, 'vehicles-fixture.csv'), [cols.join(','), ...keep.map(([r]) => cols.map((c) => q(String(pickCol(r, c)))).join(','))].join('\n') + '\n');
  const vp = {};
  for (const [mk, md, a, b] of FIXTURE_MODELS) {
    const ms = slugify(mk);
    for (const y of [0, ...Array.from({ length: b - a + 1 }, (_, i) => a + i)]) {
      const names = (vpic?.[ms]?.[y] ?? []).filter((n) => slugify(n).replace(/-/g, '') === slugify(md).replace(/-/g, '') || slugify(n).startsWith(slugify(md)));
      if (names.length) ((vp[ms] ??= {})[y] = names);
    }
  }
  writeFileSync(join(dir, 'vpic-fixture.json'), JSON.stringify(vp, null, 1) + '\n');
  console.log(`fixture: ${keep.length} EPA rows`);
}

const meta = { source: arg('--csv') ? 'file' : 'epa', vpic: !!vpic, run_url: arg('--run-url') ?? null, stats };
if (arg('--sql-out')) {
  writeFileSync(arg('--sql-out'), '-- Generated by web/scripts/catalog/import.mjs: the vehicle catalog fixture (0092). Do not edit; run the script.\n'
    + statements(catalog, meta).map((s) => s + ';').join('\n') + '\n');
}
if (flag('--write')) {
  const s = statements(catalog, meta);
  let done = 0;
  try {
    for (const q of s) { await management(q); done++; }
    console.log(`written: ${done} statements`);
  } catch (e) {
    await management(`select app.vehicle_catalog_import_fail(${lit({ error: String(e?.message ?? e).slice(0, 800) })})`).catch(() => undefined);
    throw e;
  }
}
