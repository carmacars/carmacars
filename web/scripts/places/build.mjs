#!/usr/bin/env node
// The places workflow's build step (migration 0095): reads the downloaded sources and writes one CSV per region for
// the loader, plus counts.json (per country and kind, and how many OpenStreetMap and Census places matched GeoNames).
//
//   node scripts/places/build.mjs --in <dir> --out <dir> [--regions CA-ON,US-NY | all] [--fixture]
//
// <dir> holds geonames/ (the country files CA.txt, US.txt, MX.txt, PR.txt ..., admin1CodesASCII.txt, the alternate
// names with the IATA codes as alternateNames*.txt, countryInfo.txt), osm/ (*.geojsonseq from osmium) and census/
// (the Gazetteer national places file). scripts/places/fixtures is a tiny test set in the same layout: its coordinates
// and populations are approximate and its ids above 9,900,000 are made up, so the loader refuses it in production.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { buildPlaces, parseCensusLine, parseGeonamesLine, parseOsmLine, toCsv } from '../../src/features/places/gazetteer.ts';

const arg = (k, d = null) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const IN = arg('--in', path.join(import.meta.dirname, 'fixtures'));
const OUT = arg('--out', path.join(process.cwd(), '.places-out'));
const regionsArg = arg('--regions', 'all');
const regions = regionsArg === 'all' ? null : regionsArg.split(',').map((s) => s.trim().toUpperCase()).filter(Boolean);
const fixture = process.argv.includes('--fixture') || IN.includes(`${path.sep}fixtures`);

async function* lines(file) {
  const rl = readline.createInterface({ input: fs.createReadStream(file, 'utf8'), crlfDelay: Infinity });
  for await (const l of rl) yield l;
}
const files = (dir, re) => (fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => re.test(f)).map((f) => path.join(dir, f)) : []);

const gnDir = path.join(IN, 'geonames');
const admin1Names = {};
for (const f of files(gnDir, /^admin1CodesASCII\.txt$/)) for await (const l of lines(f)) { const c = l.split('\t'); if (c[0]) admin1Names[c[0]] = c[2] || c[1]; }
const countryIds = {};
for (const f of files(gnDir, /^countryInfo\.txt$/)) for await (const l of lines(f)) { if (l.startsWith('#')) continue; const c = l.split('\t'); if (c[0] && c[16]) countryIds[c[0]] = Number(c[16]); }
const iata = {};
for (const f of files(gnDir, /^alternateNames.*\.txt$/)) for await (const l of lines(f)) { const c = l.split('\t'); if (c[2] === 'iata' && /^[A-Z]{3}$/.test(c[3] ?? '')) iata[Number(c[1])] = c[3]; }

// the GeoNames features we keep (the country files hold every feature class; most are skipped as they are read)
const geonames = [];
for (const f of files(gnDir, /^[A-Z]{2}\.txt$/)) for await (const l of lines(f)) {
  const g = parseGeonamesLine(l);
  if (g && (g.fclass === 'P' || g.fclass === 'A' || (g.fclass === 'S' && (g.fcode === 'AIRP' || /^(MALL|STDM|MUS|ZOO|AMUS|UNIV|HSTS|MNMT|THTR|TOWR|CSTL|OPRA)$/.test(g.fcode))))) geonames.push(g);
}
const osm = [];
for (const f of files(path.join(IN, 'osm'), /\.geojsonseq$/)) for await (const l of lines(f)) { const o = parseOsmLine(l); if (o) osm.push(o); }
const census = [];
for (const f of files(path.join(IN, 'census'), /\.txt$/)) {
  let header = null;
  for await (const l of lines(f)) { if (!header) { header = l.split('\t').map((x) => x.trim()); continue; } const c = parseCensusLine(l, header); if (c) census.push(c); }
}

const r = buildPlaces({ geonames, admin1Names, iata, osm, census, regions, countryIds, fixture });
fs.mkdirSync(OUT, { recursive: true });
const byRegion = new Map();
for (const p of r.places) { const k = p.region_code ?? `${p.country}-`; (byRegion.get(k) ?? byRegion.set(k, []).get(k)).push(p); }
for (const [k, rows] of byRegion) fs.writeFileSync(path.join(OUT, `${k}.csv`), toCsv(rows));
const summary = { fixture, regions: [...byRegion.keys()].sort(), places: r.places.length, counts: r.counts, merged: r.merged, sources: { geonames: geonames.length, osm: osm.length, census: census.length },
  per_region: Object.fromEntries([...byRegion].map(([k, v]) => [k, v.length])) };
fs.writeFileSync(path.join(OUT, 'counts.json'), JSON.stringify(summary, null, 1));
console.log(`places: ${r.places.length} in ${byRegion.size} regions; ${JSON.stringify(r.counts)}; matched ${r.merged.osm} OpenStreetMap and ${r.merged.census} Census places`);
