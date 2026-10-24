#!/usr/bin/env node
// An offline run of the stock photo pipeline (scripts/seo-photos/run.mjs) against a local stand-in for Wikidata,
// Wikimedia Commons, the storage API and (with --psql) a real database: the choice, the conversion to WebP without
// metadata, the stored files and the saved rows, with no request to Wikimedia. The workflow runs it before the live
// dry run; a developer runs it with the local database:
//   node scripts/seo-photos/offline-check.mjs                       dry: chooses and converts
//   node scripts/seo-photos/offline-check.mjs --psql <postgres url> write: stores into the stand-in and saves into that
//                                                                   database (migration 0137 applied; fixture rows sp37)
import { createServer } from 'node:http';
import { execFileSync, spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const i = process.argv.indexOf('--psql');
const PG = i > 0 ? process.argv[i + 1] : null;
const sharp = (await import('sharp')).default;
// a test photo: 2000 x 1200 JPEG with EXIF (the camera and a GPS-like comment) that must not survive
const jpeg = await sharp({ create: { width: 2000, height: 1200, channels: 3, background: { r: 120, g: 30, b: 40 } } })
  .withMetadata({ exif: { IFD0: { Make: 'TestCam', Model: 'Secret GPS 43.6N 79.4W' } } }).jpeg().toBuffer();
assert.ok((await sharp(jpeg).metadata()).exif, 'the test photo carries EXIF');

const stored = new Map();
const deleted = [];
const meta = (licence, artist = '<a href="//commons.wikimedia.org/wiki/User:Tester">Tester</a>', extra = {}) => Object.fromEntries(Object.entries({
  LicenseShortName: licence, LicenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0', Artist: artist, Categories: '', ...extra }).map(([k, v]) => [k, { value: v }]));
let base = '';
const page = (title, w, h, m) => ({ title, imageinfo: [{ width: w, height: h, mime: 'image/jpeg', url: `${base}/orig/${encodeURIComponent(title)}`, thumburl: `${base}/thumb/${encodeURIComponent(title)}`,
  thumbwidth: Math.min(1280, w), descriptionurl: `https://commons.wikimedia.org/wiki/${encodeURIComponent(title.replace(/ /g, '_'))}`, sha1: 'abc', extmetadata: m }] });
let FILES = {};
const files = () => ({
  'File:Toyota Camry XV50 front.jpg': page('File:Toyota Camry XV50 front.jpg', 3000, 2000, meta('CC BY-SA 4.0')),
  'File:2019 Toyota Camry SE front 01.jpg': page('File:2019 Toyota Camry SE front 01.jpg', 4000, 2600, meta('CC BY-SA 4.0', undefined, { Categories: 'Quality images|Toyota Camry (XV70)' })),
  'File:Toyota Camry XV70 rear.jpg': page('File:Toyota Camry XV70 rear.jpg', 3000, 2000, meta('CC BY-SA 4.0')),
  'File:Toyota Camry XV70 NC.jpg': page('File:Toyota Camry XV70 NC.jpg', 3000, 2000, meta('CC BY-NC 2.0')),
  'File:Toyota Camry XV70 side.jpg': page('File:Toyota Camry XV70 side.jpg', 3000, 2000, meta('CC BY 2.0'))
});
const json = (res, o) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
const srv = createServer((req, res) => { handle(req, res).catch((e) => { console.error(`stand-in: ${req.url}: ${e.message}`); failures.push(e.message); res.writeHead(500); res.end(e.message); }); });
const failures = [];
async function handle(req, res) {
  if (process.env.OFFLINE_DEBUG) console.error(`stand-in: ${req.method} ${req.url.slice(0, 120)}`);
  const u = new URL(req.url, base);
  const body = await new Promise((r) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => r(Buffer.concat(c))); });
  if (/^\/(wd|sparql|api|thumb)/.test(u.pathname) && !/^CarmaCarsStockPhotos\/1\.0 \(https:\/\/carmacars\.ca; /.test(req.headers['user-agent'] ?? '')) { res.writeHead(403); return res.end('no user agent'); }
  if (u.pathname === '/wd') {
    return json(res, { search: [{ id: 'Q100', label: 'Toyota Camry Solara', description: 'automobile model' }, { id: 'Q1', label: 'Toyota Camry', description: 'automobile model series' }] });
  }
  if (u.pathname === '/sparql') {
    const b = (item, label, extra = {}) => ({ item: { value: `http://www.wikidata.org/entity/${item}` }, itemLabel: { value: label }, ...extra });
    return json(res, { results: { bindings: [
      b('Q1', 'Toyota Camry', { cat: { value: 'Toyota Camry' } }),
      b('Q50', 'Toyota Camry (XV50)', { start: { value: '2011-08-01T00:00:00Z' }, prec: { value: '10' }, end: { value: '2017-01-01T00:00:00Z' }, img: { value: 'http://commons.wikimedia.org/wiki/Special:FilePath/Toyota%20Camry%20XV50%20front.jpg' }, cat: { value: 'Toyota Camry (XV50)' } }),
      b('Q70', 'Toyota Camry (XV70)', { start: { value: '2017-01-01T00:00:00Z' }, prec: { value: '9' }, img: { value: 'http://commons.wikimedia.org/wiki/Special:FilePath/Toyota%20Camry%20XV70%20side.jpg' }, cat: { value: 'Toyota Camry (XV70)' } }),
      b('Q99', 'Toyota Camry Hybrid', { start: { value: '2006-01-01T00:00:00Z' }, prec: { value: '9' } }),
      b('Q98', 'Toyota Camry (XV70) NASCAR', { start: { value: '2018-01-01T00:00:00Z' }, prec: { value: '9' } })
    ] } });
  }
  if (u.pathname === '/api') {
    assert.equal(u.searchParams.get('maxlag'), '5');
    if (u.searchParams.get('titles')) return json(res, { query: { pages: u.searchParams.get('titles').split('|').map((t) => FILES[t]).filter(Boolean) } });
    const s = u.searchParams.get('gsrsearch') ?? u.searchParams.get('gcmtitle') ?? '';
    if (/XV70/.test(s)) return json(res, { query: { pages: /Quality/.test(s) ? [FILES['File:2019 Toyota Camry SE front 01.jpg']] : [FILES['File:Toyota Camry XV70 rear.jpg'], FILES['File:Toyota Camry XV70 NC.jpg'], FILES['File:2019 Toyota Camry SE front 01.jpg']] } });
    return json(res, { query: { pages: [] } });
  }
  if (u.pathname.startsWith('/thumb/')) { res.writeHead(200, { 'content-type': 'image/jpeg' }); return res.end(jpeg); }
  if (u.pathname.startsWith('/storage/object/vehicle-public/') && req.method === 'POST') {
    assert.equal(req.headers['content-type'], 'image/webp');
    stored.set(u.pathname.slice('/storage/object/vehicle-public/'.length), body);
    return json(res, { Key: u.pathname });
  }
  if (u.pathname === '/storage/object/vehicle-public' && req.method === 'DELETE') { deleted.push(...JSON.parse(body).prefixes); return json(res, []); }
  if (u.pathname === '/sql') {
    const { query } = JSON.parse(body);
    const out = execFileSync('psql', ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', PG, '-c', `select coalesce(json_agg(t), '[]') from (${query}) t`], { encoding: 'utf8' });
    res.writeHead(200, { 'content-type': 'application/json' }); return res.end(out.trim());
  }
  res.writeHead(404); res.end('not found');
}
await new Promise((r) => srv.listen(0, '127.0.0.1', r));
base = `http://127.0.0.1:${srv.address().port}`;
FILES = files();

if (PG) {
  execFileSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', PG, '-c', `
    delete from vehicle_stock_photos where make = 'toyota'; delete from vehicle_stock_photo_checks where make = 'toyota';
    insert into vehicle_catalog_makes (slug, name) values ('toyota', 'Toyota') on conflict do nothing;
    insert into vehicle_catalog_models (make_slug, slug, name, key) values ('toyota', 'camry', 'Camry', 'camry') on conflict do nothing;
    insert into vehicle_catalog_years (make_slug, model_slug, year) select 'toyota', 'camry', y from generate_series(2010, 2025) y on conflict do nothing;`]);
}
const env = { ...process.env, WM_COMMONS_API: `${base}/api`, WM_WIKIDATA_API: `${base}/wd`, WM_SPARQL: `${base}/sparql`, WM_GAP_MS: '0',
  ...(PG ? { STORAGE_URL: `${base}/storage`, SERVICE_KEY: 'test-key', SQL_API_URL: `${base}/sql` } : {}) };
const manifest = join(process.env.RUNNER_TEMP ?? '/tmp', `seo-photos-offline-${process.pid}.json`);
const argv = ['--experimental-strip-types', '--no-warnings', join(HERE, 'run.mjs'), '--manifest', manifest, ...(PG ? ['--write', '--models', 'toyota/camry'] : ['--models', 'toyota/camry', '--samples', '1'])];
const code = await new Promise((r) => { const c = spawn(process.execPath, argv, { env, stdio: 'inherit' }); c.on('exit', r); });
srv.close();
assert.equal(code, 0, 'the run ends cleanly');
assert.deepEqual(failures, [], 'the stand-in saw only correct requests');
const { readFileSync, rmSync } = await import('node:fs');
const run = JSON.parse(readFileSync(manifest, 'utf8'));
rmSync(manifest);
const picks = run.picks.filter((p) => p.m === 'toyota/camry');
if (!PG) {
  assert.deepEqual(picks.map((p) => [p.y, p.f]), [['2012-2017', 'Toyota Camry XV50 front.jpg'], ['2018-2026', '2019 Toyota Camry SE front 01.jpg']].map(([y, f]) => [y.replace('2026', String(new Date().getUTCFullYear() + 1)), f]));
} else {
  assert.deepEqual(picks.map((p) => [p.y, p.f]), [['2012-2017', 'Toyota Camry XV50 front.jpg'], ['2018-2025', '2019 Toyota Camry SE front 01.jpg']], 'one photo per generation, the best licensed front view');
  assert.equal(stored.size, 4, 'two widths of two photos stored');
  for (const [k, v] of stored) {
    const m = await sharp(v).metadata();
    assert.equal(m.format, 'webp', k);
    assert.ok(!m.exif && !m.xmp && !m.icc, `${k}: no metadata`);
    assert.ok([640, 1280].includes(m.width), `${k}: width ${m.width}`);
    assert.match(k, /^seo-photos\/toyota\/camry\/(2012-2017|2018-2025)-[0-9a-f]{10}-(640|1280)\.webp$/);
  }
  const rows = JSON.parse(execFileSync('psql', ['-X', '-q', '-At', PG, '-c', `select json_agg(json_build_object('y', year_from, 'f', file_title, 'l', licence, 'a', author, 's', status, 'w', width, 'sz', sizes) order by year_from) from vehicle_stock_photos where make = 'toyota'`], { encoding: 'utf8' }));
  assert.deepEqual(rows.map((r) => [r.y, r.l, r.a, r.s, r.w, r.sz]), [[2012, 'CC BY-SA 4.0', 'Tester', 'active', 1280, [640, 1280]], [2018, 'CC BY-SA 4.0', 'Tester', 'active', 1280, [640, 1280]]]);
  const page = JSON.parse(execFileSync('psql', ['-X', '-q', '-At', PG, '-c', `select public.vehicle_stock_photo('toyota', 'camry', 2015)`], { encoding: 'utf8' }));
  assert.equal(page.generation, 'Toyota Camry (XV50)');
}
console.log(`offline check passed (${PG ? 'write' : 'dry'}): ${run.picks.length} picks, ${stored.size} files stored, ${deleted.length} deleted`);
