#!/usr/bin/env node
// The vehicle catalog import (migration 0097; docs/changes/2026-10-21-vehicle-pages.md). Run by the catalog workflow
// (.github/workflows/catalog.yml): GitHub's runners reach fueleconomy.gov and vPIC, the development sandbox cannot.
//
//   node --experimental-strip-types --no-warnings scripts/catalog/import.mjs [options]
//     --csv <file>          the EPA vehicles.csv (default: download https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip)
//     --vpic                also read vPIC's model names for each make and year (NHTSA, public domain)
//     --vpic-json <file>    vPIC's names from a file instead ({make: {year: [names]}}), as the fixture keeps them
//     --sql-out <file>      write the import as SQL (the batches, begin and finish), for a local database or a test
//     --write               apply it: over DATABASE_URL when set (COPY into the staging table), else through the
//                           Supabase Management API (SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF); only the catalog
//                           workflow writes production. Gentle (0106): --chunk rows a transaction (2000), --pause-ms
//                           between them (500), and a wait while the database is busy (--max-active sessions, 6)
//     --fixture-out <dir>   write the fixture subset (the EPA rows and vPIC names of FIXTURE_MODELS) for the tests
//     --stats <file>        write the counts (makes, models, years, trims) as JSON
//     --run-url <url>       recorded with the import (the workflow run)
//   Further sources (0115; docs/seo/coverage-2026-10-23.md). Off unless asked; the catalog workflow passes the ones
//   Program settings vpage_extra_sources lists (empty until the database has moved off the 1 GB server):
//     --vpic-export <csv>   NHTSA's vPIC database exported as make,model,year,vehicle_type,trim (the query is in the doc):
//                           the makes, models and years EPA does not rate, and the trims the VIN patterns name
//     --vpic-export-types <list>  car,mpv,truck by default; add motorcycle, bus, lsv, offroad as wanted
//     --vpic-export-known-makes   only the makes EPA has (no new make)
//     --nrcan <csv,...|download>  Natural Resources Canada's Fuel Consumption Ratings (Open Government Licence - Canada):
//                           Canadian-market models and years from 1995, with their figures where EPA has none
//     --nrcan-url <url>     a ratings file to download (repeatable; replaces the default list)
//     --wikidata <json|download>  car models before 1981 from Wikidata (CC0), names and production years only
//     --wikidata-new-makes  let Wikidata add makes EPA does not have (Studebaker, Packard); off: only known makes
//
// Sources: EPA (US Department of Energy and EPA, fueleconomy.gov: public domain); vPIC (US DOT NHTSA: public domain);
// the Canadian trim names of web/scripts/catalog/canada-trims.txt (compiled by CarmaCars from the makers' Canadian
// lineups; facts, editable in Admin > Settings > Vehicle pages).
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { attachDims, attachSafety, batches, buildCatalog, makeName, parseCsv, parseNrcanCsv, parsePopular, parseTrimList, parseVpicExport, parseWikidata } from '../../src/features/vehicles/normalise.ts';
import { slugify } from '../../src/features/vehicles/units.ts';
import { beforeBatch } from '../../src/lib/import-pace.ts';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
const flag = (k) => argv.includes(k);
const NOW_YEAR = new Date().getUTCFullYear();
// every year the sources have (the owner, October 22, 2026): EPA from 1984, vPIC from 1981, to the next model year
const YEARS = [1981, NOW_YEAR + 1];
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

/** One vPIC call: a few tries with a pause that grows when vPIC says to slow down (429, 403, 5xx); why a call failed is
 *  counted (stats.vpic_errors), so a dry run's annotations say what happened. */
const VPIC_PARALLEL = 4;
const VPIC_ERRORS = {};
async function vpicGet(url) {
  let why = '';
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(45_000) });
      if (r.ok) return await r.json();
      why = `HTTP ${r.status}`;
      if (![403, 429, 500, 502, 503, 504].includes(r.status)) break;
    } catch (e) { why = String(e?.cause?.code ?? e?.name ?? e).slice(0, 60); }
    await new Promise((res) => setTimeout(res, 2000 * 2 ** i));
  }
  VPIC_ERRORS[why] = (VPIC_ERRORS[why] ?? 0) + 1;
  throw new Error(why);
}

/** vPIC's model names: every model of each make (its spelling, "F-150" over EPA's "F150"), and each make's models of
 *  every model year from three years before its first EPA year (1981 at the earliest) to the next model year, for
 *  passenger cars, multipurpose vehicles and trucks (motorcycles, buses and trailers left out). Several thousand calls,
 *  four at a time, within a time budget: vPIC answering slowly never holds up the import (what did not answer is
 *  counted, and the catalog is built from EPA and the answers it has). */
async function vpicNames(spans) {
  const out = {};
  const t0 = Date.now(), BUDGET = 25 * 60_000;
  const jobs = [];
  for (const [make, [first, last]] of spans) {
    jobs.push([make, null, null]);
    for (let y = Math.max(YEARS[0], first - 3); y <= Math.min(YEARS[1], last + 1); y++) for (const t of ['car', 'mpv', 'truck']) jobs.push([make, y, t]);
  }
  console.log(`vpic: ${jobs.length} calls for ${spans.size} makes`);
  let failed = 0, done = 0;
  const one = vpicGet;
  const work = async () => {
    for (let job = jobs.shift(); job; job = jobs.shift()) {
      if (Date.now() - t0 > BUDGET) { failed++; continue; }
      const [make, y, type] = job;
      const url = y ? `https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMakeYear/make/${encodeURIComponent(make)}/modelyear/${y}/vehicletype/${type}?format=json`
        : `https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMake/${encodeURIComponent(make)}?format=json`;
      try {
        const j = await one(url);
        const names = [...new Set((j.Results ?? []).map((r) => String(r.Model_Name ?? '').trim()).filter(Boolean))];
        // the make's whole list stands for its spellings: filed under year 0, which adds names but no model year
        if (names.length) { const by = (out[slugify(make)] ??= {}); by[y ?? 0] = [...new Set([...(by[y ?? 0] ?? []), ...names])]; }
        done++;
      } catch { failed++; }
    }
  };
  await Promise.all(Array.from({ length: VPIC_PARALLEL }, work));
  console.log(`vpic: ${done} calls answered, ${failed} not, ${Math.round((Date.now() - t0) / 1000)} s`);
  return { names: out, failed };
}

/** vPIC's Canadian specifications (public domain): each body of a make's model years with its length, width, height,
 *  wheelbase (cm) and curb weight (kg). One call per make and year, four at a time, within its own time budget. */
async function cvsSpecs(spans) {
  const out = {}; const t0 = Date.now(), BUDGET = 20 * 60_000;
  const jobs = [];
  for (const [make, [first, last]] of spans) for (let y = Math.max(YEARS[0], first); y <= Math.min(YEARS[1], last + 1); y++) jobs.push([make, y]);
  let done = 0, failed = 0, rows = 0;
  const work = async () => {
    for (let job = jobs.shift(); job; job = jobs.shift()) {
      if (Date.now() - t0 > BUDGET) { failed++; continue; }
      const [make, y] = job;
      try {
        const j = await vpicGet(`https://vpic.nhtsa.dot.gov/api/vehicles/GetCanadianVehicleSpecifications/?Year=${y}&Make=${encodeURIComponent(make)}&Model=&units=Metric&format=json`);
        const list = (out[slugify(make)] ??= []);
        for (const res of j.Results ?? []) {
          const rec = Object.fromEntries((res.Specs ?? []).map((x) => [x.Name, String(x.Value ?? '')]));
          if (!rec.Model || list.some((x) => x.Model === rec.Model && x.MYR === rec.MYR)) continue;
          list.push({ Model: rec.Model, MYR: rec.MYR, OL: rec.OL, OW: rec.OW, OH: rec.OH, WB: rec.WB, CW: rec.CW }); rows++;
        }
        done++;
      } catch { failed++; }
    }
  };
  await Promise.all(Array.from({ length: VPIC_PARALLEL }, work));
  console.log(`cvs: ${done} calls answered, ${failed} not, ${rows} bodies, ${Math.round((Date.now() - t0) / 1000)} s`);
  return { specs: out, failed, rows };
}

/** The lines of a zip's single text file (NHTSA flat files are tab separated, Windows-1252), streamed. */
async function zipLines(urls, onLine) {
  for (const url of urls) {
    try {
      const dir = mkdtempSync(join(tmpdir(), 'nhtsa-'));
      const file = join(dir, 'f.zip');
      writeFileSync(file, await get(url, 'bytes'));
      const p = spawn('unzip', ['-p', file]);
      const rl = createInterface({ input: p.stdout.setEncoding('latin1'), crlfDelay: Infinity });
      let n = 0;
      for await (const line of rl) { n++; onLine(line.split('\t')); }
      console.log(`nhtsa: ${url}: ${n} lines`);
      return { url, lines: n };
    } catch (e) { console.log(`nhtsa: ${url}: ${String(e?.message ?? e).slice(0, 200)}`); }
  }
  return { url: null, lines: 0 };
}
const nkey = (make, model, year) => `${slugify(make)}|${String(model).trim().toUpperCase()}|${year}`;
/** NHTSA recalls (FLAT_RCL, public domain): vehicle campaigns by make, model and model year. Fields (RCL.txt): 2 CAMPNO,
 *  3 MAKETXT, 4 MODELTXT, 5 YEARTXT, 7 COMPNAME, 11 RCLTYPECD, 16 RCDATE, 20 DESC_DEFECT. */
async function nhtsaRecalls() {
  const out = new Map(); let ok = 0, bad = 0;
  const onLine = (f) => {
    const camp = f[1], year = Number(f[4]);
    if (!/^\d{2}[VETC]\d{3}0{3}$/.test(camp ?? '') || f[10] !== 'V' || !(year >= 1949 && year <= 2100)) { bad++; return; }
    const k = nkey(f[2], f[3], year);
    const list = out.get(k) ?? out.set(k, []).get(k);
    if (list.some((r) => r.campaign === camp)) return;
    const d = /^\d{8}$/.test(f[15] ?? '') ? `${f[15].slice(0, 4)}-${f[15].slice(4, 6)}-${f[15].slice(6, 8)}` : null;
    const summary = String(f[19] ?? '').replace(/\s+/g, ' ').trim();
    list.push({ campaign: camp, date: d, component: String(f[6] ?? '').trim() || null, summary: summary ? (summary.length > 320 ? summary.slice(0, 317).replace(/\s+\S*$/, '') + '...' : summary) : null });
    ok++;
  };
  // the whole file, else its two halves (NHTSA has published it both ways)
  let src = await zipLines(['https://static.nhtsa.gov/odi/ffdd/rcl/FLAT_RCL.zip'], onLine);
  if (!src.url) {
    const a = await zipLines(['https://static.nhtsa.gov/odi/ffdd/rcl/FLAT_RCL_PRE_2010.zip'], onLine);
    const b = await zipLines(['https://static.nhtsa.gov/odi/ffdd/rcl/FLAT_RCL_POST_2010.zip'], onLine);
    src = { url: [a.url, b.url].filter(Boolean).join(' + ') || null, lines: a.lines + b.lines };
  }
  return { map: out, ok, bad, url: src.url };
}
/** NHTSA complaints (FLAT_CMPL, public domain): counts by make, model and model year, and by component. Fields
 *  (CMPL.txt): 2 ODINO, 4 MAKETXT, 5 MODELTXT, 6 YEARTXT, 12 COMPDESC, 46 PROD_TYPE (V a vehicle). */
async function nhtsaComplaints() {
  const out = new Map(); const seen = new Map(); let ok = 0, bad = 0;
  const src = await zipLines(['https://static.nhtsa.gov/odi/ffdd/cmpl/FLAT_CMPL.zip'], (f) => {
    const year = Number(f[5]);
    if (!f[1] || !(year >= 1949 && year <= 2100) || (f[45] && f[45] !== 'V')) { bad++; return; }
    const k = nkey(f[3], f[4], year);
    const v = out.get(k) ?? out.set(k, { total: 0, comps: new Map() }).get(k);
    const s = seen.get(k) ?? seen.set(k, new Set()).get(k);
    if (!s.has(f[1])) { s.add(f[1]); v.total++; }
    for (const c of String(f[11] ?? '').split(':')[0].split(',').map((x) => x.trim()).filter(Boolean).slice(0, 1)) v.comps.set(c, (v.comps.get(c) ?? 0) + 1);
    ok++;
  });
  return { map: out, ok, bad, url: src.url };
}
// ---------------------------------------------------------------- further sources (0115)
const args = (k) => argv.flatMap((a, i) => (a === k ? [argv[i + 1]] : [])).filter(Boolean);
/** NRCan's ratings files (open.canada.ca dataset 98f1a129-f628-4ce4-b24d-6f16bf24dd64). The names change when NRCan adds a
 *  year: a file that does not answer is reported and skipped (the dry run lists each one's status). */
export const NRCAN_URLS = [
  'https://natural-resources.canada.ca/sites/nrcan/files/oee/files/csv/MY1995-2004%20Fuel%20Consumption%20Ratings%205-cycle.csv',
  'https://natural-resources.canada.ca/sites/nrcan/files/oee/files/csv/MY2005-2014%20Fuel%20Consumption%20Ratings%205-cycle.csv',
  'https://natural-resources.canada.ca/sites/nrcan/files/oee/files/csv/MY2015-2024%20Fuel%20Consumption%20Ratings.csv',
  'https://natural-resources.canada.ca/sites/nrcan/files/oee/files/csv/MY2025%20Fuel%20Consumption%20Ratings.csv',
  'https://natural-resources.canada.ca/sites/nrcan/files/oee/files/csv/MY2012-2024%20Battery%20Electric%20Vehicles.csv',
  'https://natural-resources.canada.ca/sites/nrcan/files/oee/files/csv/MY2012-2024%20Fuel%20Consumption%20Ratings%20(PHEVs).csv'
];
/** Wikidata's car models (Q3231690, an automobile model, and its subclasses) with the brand (else the manufacturer) and
 *  the production years, first produced before 1981. */
export const WIKIDATA_SPARQL = `SELECT ?model ?modelLabel ?makeLabel (MIN(?s) AS ?start) (MAX(?e) AS ?end) WHERE {
  ?model wdt:P31/wdt:P279* wd:Q3231690 .
  OPTIONAL { ?model wdt:P1716 ?brand } OPTIONAL { ?model wdt:P176 ?mfr }
  BIND(COALESCE(?brand, ?mfr) AS ?make) FILTER(BOUND(?make))
  { ?model wdt:P571 ?s } UNION { ?model wdt:P2031 ?s }
  OPTIONAL { { ?model wdt:P576 ?e } UNION { ?model wdt:P2032 ?e } }
  FILTER(YEAR(?s) < 1981)
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
} GROUP BY ?model ?modelLabel ?makeLabel`;
const decode = (bytes) => { const u = new TextDecoder('utf-8').decode(bytes); return u.includes('\uFFFD') ? new TextDecoder('latin1').decode(bytes) : u; };
async function extraSources() {
  const out = []; const report = {};
  const ve = arg('--vpic-export');
  if (ve) {
    const types = new Set(String(arg('--vpic-export-types', 'car,mpv,truck')).split(',').map((x) => x.trim().toLowerCase()).filter(Boolean));
    const rows = parseVpicExport(readFileSync(ve, 'utf8'), types);
    out.push({ source: 'vpicdb', rows, newMakes: !flag('--vpic-export-known-makes'), years: YEARS });
    report.vpicdb = { rows: rows.length, types: [...types] };
  }
  const nr = arg('--nrcan');
  if (nr) {
    const rows = []; const files = {};
    const urls = nr === 'download' ? (args('--nrcan-url').length ? args('--nrcan-url') : NRCAN_URLS) : nr.split(',');
    for (const u of urls) {
      try { const text = /^https?:/.test(u) ? decode(await get(u, 'bytes')) : readFileSync(u, 'utf8'); const r = parseNrcanCsv(text); rows.push(...r); files[u] = r.length; }
      catch (e) { files[u] = `skipped: ${String(e?.message ?? e).slice(0, 120)}`; }
    }
    out.push({ source: 'nrcan', rows, newMakes: false, years: [1995, YEARS[1]] });
    report.nrcan = { rows: rows.length, files };
  }
  const wd = arg('--wikidata');
  if (wd) {
    let json;
    if (wd === 'download') {
      json = await get(`https://query.wikidata.org/sparql?format=json&query=${encodeURIComponent(WIKIDATA_SPARQL)}`, 'json');
    } else json = JSON.parse(readFileSync(wd, 'utf8'));
    const rows = parseWikidata(json, YEARS[0] - 1);
    out.push({ source: 'wikidata', rows, newMakes: flag('--wikidata-new-makes'), years: [1900, YEARS[0] - 1] });
    report.wikidata = { rows: rows.length, models: json?.results?.bindings?.length ?? 0 };
  }
  return { sources: out, report };
}

const toMap = (o) => new Map(Object.entries(o).map(([m, ys]) => [m, new Map(Object.entries(ys).map(([y, n]) => [Number(y), n]))]));

// ---------------------------------------------------------------- SQL
// a fixed dollar quote (the output is the same on every run), a random one only if the data ever contains it
const lit = (o) => { const j = JSON.stringify(o); const t = j.includes('$catalog$') ? `$c${randomBytes(4).toString('hex')}$` : '$catalog$'; return `${t}${j}${t}::jsonb`; };
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


/** Coverage of each figure: the share of trim pages (and of all model years) whose model year has it from a source. */
function coverage(c, trimPages) {
  const yr = new Map(c.years.map((y) => [`${y.make}|${y.model}|${y.year}`, y]));
  const trimYears = [...trimPages].map((k) => yr.get(k.split('|').slice(0, 3).join('|'))).filter(Boolean);
  const has = {
    'L/100 km or kWh/100 km': (y) => y.variants.some((v) => v.l100_comb || v.kwh100), 'MPG (US)': (y) => y.variants.some((v) => v.mpg_comb),
    'annual fuel cost (EPA)': (y) => y.variants.some((v) => v.fuel_cost_usd), 'CO2 g/km': (y) => y.variants.some((v) => v.co2_g_km !== null && v.co2_g_km !== undefined),
    'displacement and cylinders': (y) => y.variants.some((v) => v.displ && v.cyl), transmission: (y) => y.variants.some((v) => v.trans), drive: (y) => y.variants.some((v) => v.drive),
    'EV range': (y) => y.variants.some((v) => v.ev_range_km), 'battery kWh': (y) => y.variants.some((v) => v.battery_kwh), 'charge time 240 V': (y) => y.variants.some((v) => v.charge240_h),
    'luggage volume': (y) => y.variants.some((v) => v.luggage_cuft), 'length, width, height, wheelbase': (y) => (y.dims ?? []).some((d) => d.length_cm && d.wheelbase_cm),
    'curb weight': (y) => (y.dims ?? []).some((d) => d.curb_kg), 'NHTSA recalls (one or more)': (y) => (y.recalls ?? []).length > 0, 'NHTSA complaints (one or more)': (y) => (y.complaints?.total ?? 0) > 0,
    'horsepower, torque, 0 to 100 km/h, top speed, fuel tank, towing': () => false
  };
  const pct = (xs, f) => (xs.length ? Math.round((1000 * xs.filter(f).length) / xs.length) / 10 : 0);
  return Object.fromEntries(Object.entries(has).map(([k, f]) => [k, { trims_pct: pct(trimYears, f), model_years_pct: pct(c.years, f) }]));
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
else if (flag('--vpic')) {
  // each EPA make with its first and last year (vPIC is asked by the EPA spelling's shown name)
  const spans = new Map();
  for (const r of rows) {
    const n = makeName(String(r.make ?? '')); const y = Number(r.year);
    if (!n || !y) continue;
    const s = spans.get(n) ?? [y, y]; spans.set(n, [Math.min(s[0], y), Math.max(s[1], y)]);
  }
  const v = await vpicNames(spans); vpic = v.names; vpicFailed = v.failed;
}
const extra = await extraSources();
if (extra.sources.length) console.log(`extra: ${JSON.stringify(extra.report)}`);
const catalog = buildCatalog(rows, { years: YEARS, vpic: vpic ? toMap(vpic) : undefined, trimLines, popular, extra: extra.sources });

// the Canadian dimensions (vPIC) and NHTSA's recalls and complaints, each year's
let cvs = null, cvsFailed = 0, nh = { recalls: null, complaints: null };
if (arg('--cvs-json')) cvs = JSON.parse(readFileSync(arg('--cvs-json'), 'utf8'));
else if (flag('--vpic')) { const spans = new Map(); for (const m of catalog.makes) { const ys = catalog.years.filter((y) => y.make === m.slug && y.sources.includes('epa')).map((y) => y.year); if (ys.length) spans.set(m.name, [Math.min(...ys), Math.max(...ys)]); } const r = await cvsSpecs(spans); cvs = r.specs; cvsFailed = r.failed; }
const dimsAttached = cvs ? attachDims(catalog, new Map(Object.entries(cvs))) : 0;
if (arg('--nhtsa-json')) {
  const j = JSON.parse(readFileSync(arg('--nhtsa-json'), 'utf8'));
  nh = { recalls: { map: new Map(Object.entries(j.recalls)) }, complaints: { map: new Map(Object.entries(j.complaints).map(([k, v]) => [k, { total: v.total, comps: new Map(Object.entries(v.comps)) }])) } };
} else if (flag('--nhtsa')) nh = { recalls: await nhtsaRecalls(), complaints: await nhtsaComplaints() };
const safety = nh.recalls ? attachSafety(catalog, nh.recalls.map, nh.complaints?.map ?? new Map()) : { recalls: 0, complaints: 0 };

const trimCount = catalog.trim_lines.reduce((n, t) => n + t.trims.length * (t.to - t.from + 1), 0);
// the trim pages there will be: each line's trims in the model years the catalog has (a name twice in a year once)
const yearSet = new Set(catalog.years.map((y) => `${y.make}|${y.model}|${y.year}`));
const trimPages = new Set();
for (const t of catalog.trim_lines) for (let y = t.from; y <= t.to; y++) if (yearSet.has(`${t.make}|${t.model}|${y}`)) for (const n of t.trims) trimPages.add(`${t.make}|${t.model}|${y}|${n.toLowerCase()}`);
const popSet = new Set(catalog.popular.map((p) => `${p.make}|${p.model}`));
const stats = {
  epa_rows: rows.length, makes: catalog.makes.length, models: catalog.models.length, model_years: catalog.years.length,
  model_years_with_specs: catalog.years.filter((y) => y.variants.length).length, powertrains: catalog.years.reduce((n, y) => n + y.variants.length, 0),
  trim_lines: catalog.trim_lines.length, trim_lines_unmatched: trimLines.length - catalog.trim_lines.length, trim_pages_upper_bound: trimCount,
  models_two_years: catalog.models.filter((m) => catalog.years.filter((y) => y.make === m.make && y.model === m.slug).length >= 2).length,
  trim_pages: trimPages.size, pages: catalog.makes.length + catalog.models.length + catalog.years.length + trimPages.size,
  popular_years_from_2015: catalog.years.filter((y) => y.year >= 2015 && popSet.has(`${y.make}|${y.model}`)).length,
  first_year: Math.min(...catalog.years.map((y) => y.year)), last_year: Math.max(...catalog.years.map((y) => y.year)),
  models_vpic_only: catalog.models.filter((m) => !m.sources.includes('epa')).length, model_years_vpic_only: catalog.years.filter((y) => !y.sources.includes('epa')).length,
  largest_sitemap_file: Math.max(0, ...Object.values([...catalog.models.map((m) => `${m.make}-models`), ...catalog.years.map((y) => `${y.make}-years`), ...[...trimPages].map((t) => `${t.split('|')[0]}-trims`)]
    .reduce((n, k) => { n[k] = (n[k] ?? 0) + 1; return n; }, {}))),
  model_years_before_1984: catalog.years.filter((y) => y.year < 1984).length, batches: batches(catalog).length,
  // the size the catalog will take in the database: its JSON, compressed as jsonb is (measured 0.45; 0.75 for margin),
  // and the trims (about 300 bytes a row with its indexes). The import refuses to start over the Admin's cap.
  batch_json_bytes: batches(catalog).reduce((n, b) => n + JSON.stringify(b).length, 0),
  cvs_failed_calls: cvsFailed, vpic_errors: VPIC_ERRORS, cvs_bodies_attached: dimsAttached, recalls_attached: safety.recalls, complaints_attached: safety.complaints,
  nhtsa_recall_rows: nh.recalls?.ok ?? null, nhtsa_recall_rows_skipped: nh.recalls?.bad ?? null, nhtsa_complaint_rows: nh.complaints?.ok ?? null, nhtsa_complaint_rows_skipped: nh.complaints?.bad ?? null,
  nhtsa_recalls_url: nh.recalls?.url ?? null, nhtsa_complaints_url: nh.complaints?.url ?? null,
  coverage: coverage(catalog, trimPages),
  extra: extra.report, ...Object.fromEntries(['vpicdb', 'nrcan', 'wikidata'].filter((k) => extra.report[k]).map((k) => [`by_${k}`, {
    makes_new: catalog.makes.filter((m) => catalog.models.filter((x) => x.make === m.slug).every((x) => x.sources.length === 1 && x.sources[0] === k)).length,
    models: catalog.models.filter((m) => m.sources.includes(k)).length, models_only: catalog.models.filter((m) => m.sources.length === 1 && m.sources[0] === k).length,
    model_years_only: catalog.years.filter((y) => y.sources.length === 1 && y.sources[0] === k).length,
    model_years_with_its_figures: k === 'nrcan' ? catalog.years.filter((y) => y.variants.some((v) => v.src === 'nrcan')).length : undefined }])),
  popular: catalog.popular.length, popular_unmatched: popular.length - catalog.popular.length, vpic_failed_calls: vpicFailed, seconds: Math.round((Date.now() - t0) / 1000)
};
const unmatched = [...trimLines.filter((t) => !catalog.trim_lines.some((c) => c.make === t.make && c.from === t.from && c.trims.join() === t.trims.join())).map((t) => `${t.make}/${t.model}`),
  ...popular.filter((p) => !catalog.popular.some((c) => c.make === p.make && slugify(c.model).replace(/-/g, '') === slugify(p.model).replace(/-/g, ''))).map((p) => `popular ${p.make}/${p.model}`)];
stats.projected_bytes = Math.round(stats.batch_json_bytes * 0.75 + stats.trim_pages * 300);
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
    'city08', 'city08U', 'highway08', 'highway08U', 'comb08', 'comb08U', 'combE', 'range', 'rangeA', 'co2TailpipeGpm', 'fuelCost08', 'charge240', 'lv2', 'lv4', 'hlv', 'evMotor'];
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
  // the Canadian specifications and NHTSA records of the fixture's model years
  const inFix = (make, name, year) => FIXTURE_MODELS.some(([mk, md, a, b]) => slugify(mk) === make && year >= a && year <= b && key(name).startsWith(key(md)));
  const yy = (v) => { const n = Number(v); return String(v).length === 4 ? n : n < 50 ? 2000 + n : 1900 + n; };
  const cf = {};
  for (const [make, list] of Object.entries(cvs ?? {})) for (const r of list) if (inFix(make, r.Model, yy(r.MYR))) (cf[make] ??= []).push(r);
  writeFileSync(join(dir, 'cvs-fixture.json'), JSON.stringify(cf, null, 1) + '\n');
  const nf = { recalls: {}, complaints: {} };
  for (const [k, v] of nh.recalls?.map ?? []) { const [make, model, year] = k.split('|'); if (inFix(make, model, Number(year))) nf.recalls[k] = v.slice(0, 12); }
  for (const [k, v] of nh.complaints?.map ?? []) { const [make, model, year] = k.split('|'); if (inFix(make, model, Number(year))) nf.complaints[k] = { total: v.total, comps: Object.fromEntries(v.comps) }; }
  writeFileSync(join(dir, 'nhtsa-fixture.json'), JSON.stringify(nf, null, 1) + '\n');
  console.log(`fixture: ${keep.length} EPA rows`);
}

const meta = { source: arg('--csv') ? 'file' : 'epa', vpic: !!vpic, run_url: arg('--run-url') ?? null, stats: { ...stats, seconds: undefined } };
if (arg('--sql-out')) {
  writeFileSync(arg('--sql-out'), '-- Generated by web/scripts/catalog/import.mjs: the vehicle catalog fixture (0097). Do not edit; run the script.\n'
    + statements(catalog, meta).map((s) => s + ';').join('\n') + '\n');
}
if (flag('--write')) await write(catalog, meta);

// ---------------------------------------------------------------- the write (0106: gentle on the database)
// The batches are staged (COPY into app.vehicle_catalog_staging over DATABASE_URL when the workflow has the database
// password, else each batch's rows through the Management API), then merged CHUNK rows a transaction with a pause and
// a busy check before each (src/lib/import-pace.ts); the trims are built a make a transaction; the catalog-wide
// refreshes (the trims' numbering, every car's catalog match and listing row) run once, in finish.
async function connect() {
  const url = process.env.DATABASE_URL;
  if (url) {
    const { default: postgres } = await import('postgres');
    const sql = postgres(url, { max: 1, onnotice: () => {}, connection: { statement_timeout: 0, application_name: 'carmacars catalog import' } });
    return {
      mode: 'database', end: () => sql.end(),
      one: async (q) => (await sql.unsafe(q))[0],
      copy: async (rows) => {
        const w = await sql.unsafe('copy app.vehicle_catalog_staging (kind, make_slug, row) from stdin with (format csv)').writable();
        const csv = (v) => `"${String(v).replace(/"/g, '""')}"`;
        await pipeline(Readable.from(rows.map((r) => `${csv(r.kind)},${csv(r.make)},${csv(JSON.stringify(r.row))}\n`)), w);
      }
    };
  }
  return { mode: 'management api', end: async () => {}, one: async (q) => JSON.parse(await management(q))[0], copy: null };
}

/** a batch as the staged rows (the order app.vehicle_catalog_import_stage keeps): make, models, years, trim lines */
function stagedRows(b) {
  const make = b.make.slug;
  return [{ kind: 'make', make, row: b.make }, ...b.models.map((row) => ({ kind: 'model', make, row })), ...b.years.map((row) => ({ kind: 'year', make, row })),
    ...(b.trim_lines ? [{ kind: 'trim_lines', make, row: b.trim_lines }] : [])];
}

async function write(catalog, meta) {
  const CHUNK = Number(arg('--chunk', '2000'));
  const db = await connect();
  const pace = { pauseMs: Number(arg('--pause-ms', '500')), maxActive: Number(arg('--max-active', '6')),
    // through the Management API the question itself crosses the internet
    maxProbeMs: db.mode === 'database' ? 1_500 : 4_000, log: (l) => console.log(`pace: ${l}`) };
  const probe = () => db.one('select app.db_busy() as b').then((r) => r.b);
  let waited = 0;
  const gentle = async () => { const r = await beforeBatch(probe, pace); waited += r.waitedMs; };
  const t0 = Date.now();
  console.log(`write: through the ${db.mode}, ${CHUNK} rows a transaction`);
  try {
    await db.one(`select app.vehicle_catalog_import_begin(${lit(meta)}) as id`);
    const all = batches(catalog);
    if (db.copy) {
      const rows = all.flatMap(stagedRows);
      for (let i = 0; i < rows.length; i += CHUNK) { await gentle(); await db.copy(rows.slice(i, i + CHUNK)); }
      console.log(`staged: ${rows.length} rows (COPY)`);
    } else {
      for (const b of all) { await gentle(); await db.one(`select app.vehicle_catalog_import_stage(${lit(b)}) as n`); }
      console.log(`staged: ${all.length} batches`);
    }
    let merged = 0;
    for (;;) {
      await gentle();
      const { r } = await db.one(`select app.vehicle_catalog_import_merge(${CHUNK}) as r`);
      merged += Number(r.merged);
      if (Number(r.merged) === 0 || Number(r.left) === 0) break;
    }
    console.log(`merged: ${merged} rows`);
    await db.one(`select app.vehicle_catalog_import_popular(${lit(catalog.popular)}) as n`);
    for (const m of catalog.makes) { await gentle(); await db.one(`select app.vehicle_catalog_import_trims('${m.slug.replace(/'/g, "''")}') as n`); }
    await gentle();
    const { f } = await db.one(`select app.vehicle_catalog_import_finish(${lit({ makes: catalog.makes.map((m) => m.slug), trims_built: true })}) as f`);
    console.log(`written: ${JSON.stringify(f)} in ${Math.round((Date.now() - t0) / 1000)} s, ${Math.round(waited / 1000)} s of it waiting for a quiet database`);
  } catch (e) {
    await db.one(`select app.vehicle_catalog_import_fail(${lit({ error: String(e?.message ?? e).slice(0, 800) })})`).catch(() => undefined);
    throw e;
  } finally {
    await db.end();
  }
}
