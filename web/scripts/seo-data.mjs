// The seo-data import (release 35, part M; migration 1100; .github/workflows/seo-data.yml): downloads the sourced page
// data on the runner and writes it as chunk files for public.server_seo_data_load, which the workflow loads through the
// existing database path (scripts/deploy/sb.sh). Nothing is committed: the data lives in the database only.
//
//   OUT=<dir> node --experimental-strip-types web/scripts/seo-data.mjs gtfs            the agencies' GTFS stops (FEEDS below)
//   OUT=<dir> node --experimental-strip-types web/scripts/seo-data.mjs osm             hotels from OpenStreetMap (Overpass)
//   OUT=<dir> TARGETS=<file> node ... seo-data.mjs specs                               fueleconomy.gov and NHTSA, for the targets
//   OUT=<dir> CSV_URL=<https url> KIND=specs|maintenance node ... seo-data.mjs csv     a curated spec or cost table
//
// Each chunk file is {kind, rows, prune?}. A feed or an answer that fails is reported and skipped: the run goes on.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { chunks, curatedSpecRows, fuelEconomyRows, gtfsStops, osmHotels, parseCsv, ratingRows, recallRow } from '../src/features/seo/seo-data.ts';

const OUT = process.env.OUT ?? 'seo-data-out';
const UA = 'CarmaCars seo-data import (github actions)';
const NOW = new Date().toISOString();
fs.mkdirSync(OUT, { recursive: true });
let n = 0;
const write = (kind, rows, prune) => {
  const parts = chunks(rows);
  parts.forEach((c, i) => { fs.writeFileSync(path.join(OUT, `${String(++n).padStart(4, '0')}-${kind}.json`), JSON.stringify({ kind, rows: c, ...(prune && i === parts.length - 1 ? { prune } : {}) })); });
  console.log(`::notice title=seo-data::${kind}: ${rows.length} rows in ${parts.length} files`);
};
const get = async (url, opt = {}) => {
  const r = await fetch(url, { ...opt, headers: { 'user-agent': UA, ...(opt.headers ?? {}) }, signal: AbortSignal.timeout(180_000) });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r;
};

// The official GTFS feeds. "ckan:" resolves the Toronto open data package to its GTFS zip on each run.
const FEEDS = [
  { agency: 'GO Transit', url: 'https://assets.metrolinx.com/raw/upload/Documents/Metrolinx/Open%20Data/GO-GTFS.zip', licence: 'Metrolinx Open Data Licence', page: 'https://www.metrolinx.com/en/about-us/open-data' },
  { agency: 'TTC', url: 'ckan:ttc-routes-and-schedules', licence: 'Open Government Licence - Toronto', page: 'https://open.toronto.ca/dataset/ttc-routes-and-schedules/' },
  { agency: 'MiWay', url: 'https://www.miapp.ca/GTFS/google_transit.zip', licence: 'City of Mississauga Open Data Licence', page: 'https://www.mississauga.ca/miway-transit/developer-download/' },
  { agency: 'YRT', url: 'https://www.yrt.ca/google/google_transit.zip', licence: 'York Region Open Data Licence', page: 'https://www.yrt.ca/en/about-us/open-data.aspx' },
  { agency: 'Brampton Transit', url: 'https://www.brampton.ca/EN/City-Hall/OpenGov/Open-Data-Catalogue/Documents/Google_Transit.zip', licence: 'City of Brampton Open Data Licence', page: 'https://geohub.brampton.ca/' },
  { agency: 'DRT', url: 'https://maps.durham.ca/OpenDataGTFS/GTFS_Durham_TXT.zip', licence: 'Region of Durham Open Data Licence', page: 'https://opendata.durham.ca/' }
];

async function ckanZip(id) {
  const j = await (await get(`https://ckan0.cf.opendata.inter.prod-toronto.ca/api/3/action/package_show?id=${encodeURIComponent(id)}`)).json();
  const res = (j?.result?.resources ?? []).find((r) => /\.zip($|\?)/i.test(r.url ?? '') || /zip/i.test(r.format ?? ''));
  if (!res) throw new Error(`no zip in ${id}`);
  return res.url;
}

async function gtfs() {
  for (const f of FEEDS) {
    try {
      const url = f.url.startsWith('ckan:') ? await ckanZip(f.url.slice(5)) : f.url;
      const buf = Buffer.from(await (await get(url)).arrayBuffer());
      const zip = path.join(OUT, 'feed.zip');
      fs.writeFileSync(zip, buf);
      const text = execFileSync('unzip', ['-p', zip, 'stops.txt'], { maxBuffer: 256 * 1024 * 1024 }).toString('utf8');
      fs.rmSync(zip);
      const rows = gtfsStops(f, parseCsv(text), NOW);
      write('pois', rows, { source: 'gtfs', agency: f.agency, before: NOW });
    } catch (e) { console.log(`::warning title=seo-data::${f.agency} GTFS skipped (${e instanceof Error ? e.message : e})`); }
  }
}

async function osm() {
  // the Toronto area and around (the delivery area with margin): named hotels and motels, nodes and buildings
  const q = '[out:json][timeout:180];(nwr["tourism"~"^(hotel|motel)$"]["name"](43.30,-80.30,44.40,-78.60););out center tags;';
  try {
    const j = await (await get('https://overpass-api.de/api/interpreter', { method: 'POST', body: new URLSearchParams({ data: q }) })).json();
    write('pois', osmHotels(j, NOW), { source: 'osm', agency: '', before: NOW });
  } catch (e) { console.log(`::warning title=seo-data::OpenStreetMap hotels skipped (${e instanceof Error ? e.message : e})`); }
}

async function specs() {
  const targets = JSON.parse(fs.readFileSync(process.env.TARGETS ?? 'targets.json', 'utf8'));
  const rows = [];
  for (const t of targets.slice(0, Number(process.env.MAX_TARGETS ?? 400))) {
    const q = `year=${t.year}&make=${encodeURIComponent(t.make)}&model=${encodeURIComponent(t.model)}`;
    try {
      const menu = await (await get(`https://www.fueleconomy.gov/ws/rest/vehicle/menu/options?${q}`, { headers: { accept: 'application/json' } })).json();
      const items = [menu?.menuItem ?? []].flat().slice(0, 6);
      for (const it of items) {
        const v = await (await get(`https://www.fueleconomy.gov/ws/rest/vehicle/${encodeURIComponent(it.value)}`, { headers: { accept: 'application/json' } })).json();
        rows.push(...fuelEconomyRows({ ...v, model: it.text ?? v.model }, t, NOW));
      }
    } catch (e) { console.log(`::warning title=seo-data::fueleconomy.gov ${t.year} ${t.make} ${t.model} skipped (${e instanceof Error ? e.message : e})`); }
    try {
      const r = await (await get(`https://api.nhtsa.gov/recalls/recallsByVehicle?make=${encodeURIComponent(t.make)}&model=${encodeURIComponent(t.model)}&modelYear=${t.year}`)).json();
      const row = recallRow(r, t, NOW); if (row) rows.push(row);
    } catch (e) { console.log(`::warning title=seo-data::NHTSA recalls ${t.year} ${t.make} ${t.model} skipped (${e instanceof Error ? e.message : e})`); }
    try {
      const list = await (await get(`https://api.nhtsa.gov/SafetyRatings/modelyear/${t.year}/make/${encodeURIComponent(t.make)}/model/${encodeURIComponent(t.model)}`)).json();
      const id = list?.Results?.[0]?.VehicleId;
      if (id) { const r = await (await get(`https://api.nhtsa.gov/SafetyRatings/VehicleId/${id}`)).json(); rows.push(...ratingRows(r?.Results?.[0] ?? {}, t, NOW)); }
    } catch (e) { console.log(`::warning title=seo-data::NHTSA ratings ${t.year} ${t.make} ${t.model} skipped (${e instanceof Error ? e.message : e})`); }
  }
  write('specs', rows);
}

async function csv() {
  const url = process.env.CSV_URL ?? '';
  if (!/^https:\/\//.test(url)) { console.log('::notice title=seo-data::no CSV_URL: nothing to load'); return; }
  const rows = parseCsv(await (await get(url)).text());
  if (process.env.KIND === 'maintenance') {
    const ok = rows.filter((r) => r.segment && /^\d+$/.test(r.per_year_cents ?? '') && /^\d+$/.test(r.per_10k_km_cents ?? '') && (r.assumptions ?? '').length >= 20 && r.source && /^https:\/\//.test(r.source_url ?? ''))
      .map((r) => ({ make: r.make ?? '', segment: r.segment, per_year_cents: Number(r.per_year_cents), per_10k_km_cents: Number(r.per_10k_km_cents), assumptions: r.assumptions, source: r.source, source_url: r.source_url, fetched_at: r.fetched_at || NOW }));
    console.log(`::notice title=seo-data::maintenance: ${ok.length} rows kept, ${rows.length - ok.length} refused (missing a value or its source)`);
    write('maintenance', ok);
  } else {
    const r = curatedSpecRows(rows, NOW);
    console.log(`::notice title=seo-data::specs CSV: ${r.rows.length} rows kept, ${r.rejected} refused (missing a value or its source)`);
    write('specs', r.rows);
  }
}

const cmd = process.argv[2];
if (cmd === 'gtfs') await gtfs();
else if (cmd === 'osm') await osm();
else if (cmd === 'specs') await specs();
else if (cmd === 'csv') await csv();
else { console.error('usage: seo-data.mjs gtfs|osm|specs|csv'); process.exit(2); }
