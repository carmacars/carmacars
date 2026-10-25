#!/usr/bin/env node
// An offline run of the stock photo pipeline (scripts/seo-photos/run.mjs) against a local stand-in for Wikidata,
// Wikimedia Commons, the storage API and (with --psql) a real database: the choice, the conversion to WebP without
// metadata, the stored files and the saved rows, with no request to Wikimedia. The workflow runs it before the live
// dry run; a developer runs it with the local database:
//   node scripts/seo-photos/offline-check.mjs                       dry: chooses and converts
//   node scripts/seo-photos/offline-check.mjs --psql <postgres url> write: stores into the stand-in and saves into that
//                                                                   database (migration 0149 applied; fixture rows sp37)
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
  if (/^\/(wd|api|thumb|wp|ov)/.test(u.pathname) && !/^CarmaCarsStockPhotos\/1\.0 \(https:\/\/carmacars\.ca; /.test(req.headers['user-agent'] ?? '')) { res.writeHead(403); return res.end('no user agent'); }
  if (u.pathname === '/wd') {
    assert.equal(u.searchParams.get('maxlag'), '5');
    const act = u.searchParams.get('action');
    if (act === 'wbsearchentities') return json(res, { search: [{ id: 'Q100', label: 'Toyota Camry Solara' }, { id: 'Q7', label: 'Toyota Camry', description: 'disambiguation page' }, { id: 'Q1', label: 'Toyota Camry' }] });
    const t = (time, precision = 9) => ({ mainsnak: { datavalue: { value: { time, precision } } }, rank: 'normal' });
    const str = (v) => ({ mainsnak: { datavalue: { value: v } }, rank: 'normal' });
    const item = (id) => ({ mainsnak: { datavalue: { value: { id } } }, rank: 'normal' });
    const E = {
      Q7: { labels: { en: { value: 'Toyota Camry' } }, claims: { P31: [item('Q4167410')] } },
      Q1: { labels: { en: { value: 'Toyota Camry' } }, claims: { P176: [item('Q53268')], P373: [str('Toyota Camry')] }, sitelinks: { enwiki: { site: 'enwiki', title: 'Toyota Camry' } } },
      Q50: { labels: { en: { value: 'Toyota Camry (XV50)' } }, claims: { P571: [t('+2011-08-00T00:00:00Z', 10)], P2669: [t('+2017-00-00T00:00:00Z')], P18: [str('Toyota Camry XV50 front.jpg')], P373: [str('Toyota Camry (XV50)')] } },
      Q70: { labels: { en: { value: 'Toyota Camry (XV70)' } }, claims: { P571: [t('+2017-00-00T00:00:00Z')], P18: [str('Toyota Camry XV70 side.jpg')], P373: [str('Toyota Camry (XV70)')] } },
      Q99: { labels: { en: { value: 'Toyota Camry Hybrid' } }, claims: { P571: [t('+2006-00-00T00:00:00Z')] } },
      Q98: { labels: { en: { value: 'Toyota Camry (XV70) NASCAR' } }, claims: { P571: [t('+2018-00-00T00:00:00Z')] } }
    };
    if (act === 'wbgetentities') return json(res, { entities: Object.fromEntries(u.searchParams.get('ids').split('|').filter((id) => E[id]).map((id) => [id, { id, ...E[id] }])) });
    if (act === 'query') {
      assert.equal(u.searchParams.get('srsearch'), 'haswbstatement:P179=Q1|P279=Q1|P361=Q1|P31=Q1');
      return json(res, { query: { search: ['Q50', 'Q70', 'Q99', 'Q98'].map((title) => ({ title })) } });
    }
  }
  // English Wikipedia: the Camry's article (three generations; the XV70's years and image only in its own article)
  if (u.pathname === '/wp') {
    const page = u.searchParams.get('page');
    const W = {
      'Toyota Camry': `Intro.\n== Seventh generation (XV40; 2006) ==\n{{Infobox automobile\n| production = January 2006 – 2011\n| model_years = 2007–2011\n}}\n== Eighth generation (XV50; 2011) ==\n{{Infobox automobile\n| image = Toyota Camry XV50 front.jpg\n| production = August 2011 – 2017\n| model_years = 2012–2017\n}}\n== Ninth generation (XV70; 2017) ==\n{{Main|Toyota Camry (XV70)}}\n== Sales ==\n`,
      'Toyota Camry (XV70)': `{{Infobox automobile\n| image = Toyota Camry XV70 side.jpg\n| production = 2017 – present\n| model_years = 2018–present\n}}`
    };
    return json(res, W[page] ? { parse: { title: page, wikitext: W[page] } } : { error: { code: 'missingtitle' } });
  }
  // Openverse: two hits for the XV40 years; the better one's source page does not show its licence and is refused
  if (u.pathname.startsWith('/ov/images/')) {
    assert.equal(u.searchParams.get('license'), 'cc0,pdm,by,by-sa');
    if (!/Toyota Camry 201[01]$/.test(u.searchParams.get('q') ?? '')) return json(res, { results: [] });
    const hit = (id, title, w) => ({ id, title, creator: 'Flickr Tester', creator_url: 'https://www.flickr.com/people/tester', license: 'by-sa', license_version: '2.0', url: `${base}/thumb/ov-${id}.jpg`,
      foreign_landing_url: `${base}/ov-page/${id}`, width: w, height: Math.round(w / 1.5), source: 'flickr', provider: 'flickr', filetype: 'jpg' });
    return json(res, { results: [hit('a1', '2010 Toyota Camry LE front', 4000), hit('b2', '2010 Toyota Camry SE front', 3000)] });
  }
  if (u.pathname.startsWith('/ov-page/')) {
    res.writeHead(200, { 'content-type': 'text/html' });
    return res.end(u.pathname.endsWith('b2') ? '<a href="https://creativecommons.org/licenses/by-sa/2.0/">Some rights reserved</a>' : '<p>All rights reserved</p>');
  }
  if (u.pathname === '/api') {
    assert.equal(u.searchParams.get('maxlag'), '5');
    if (u.searchParams.get('list') === 'categorymembers') return json(res, { query: { categorymembers: [{ title: 'Category:Toyota Camry (XV50)' }, { title: 'Category:Toyota Camry (XV70)' }] } });
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
const env = { ...process.env, WM_COMMONS_API: `${base}/api`, WM_WIKIDATA_API: `${base}/wd`, WM_WIKIPEDIA_API: `${base}/wp`, WM_OPENVERSE_API: `${base}/ov`, WM_GAP_MS: '0',
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
  assert.deepEqual(picks.map((p) => [p.y, p.f, p.src]), [['2010-2011', '2010 Toyota Camry SE front [openverse b2]', 'Flickr via Openverse'], ['2012-2017', 'Toyota Camry XV50 front.jpg', 'Wikimedia Commons'],
    ['2018-2027', '2019 Toyota Camry SE front 01.jpg', 'Wikimedia Commons']].map(([y, f, w]) => [y.replace('2027', String(new Date().getUTCFullYear() + 1)), f, w]),
    'Wikipedia generations (one from its own article), Commons first, Openverse only when its source page confirms the licence');
} else {
  assert.deepEqual(picks.map((p) => [p.y, p.f]), [['2010-2011', '2010 Toyota Camry SE front [openverse b2]'], ['2012-2017', 'Toyota Camry XV50 front.jpg'], ['2018-2025', '2019 Toyota Camry SE front 01.jpg']], 'one photo per generation, the best licensed front view');
  assert.equal(stored.size, 6, 'two widths of three photos stored');
  for (const [k, v] of stored) {
    const m = await sharp(v).metadata();
    assert.equal(m.format, 'webp', k);
    assert.ok(!m.exif && !m.xmp && !m.icc, `${k}: no metadata`);
    assert.ok([640, 1280].includes(m.width), `${k}: width ${m.width}`);
    assert.match(k, /^seo-photos\/toyota\/camry\/(2010-2011|2012-2017|2018-2025)-[0-9a-f]{10}-(640|1280)\.webp$/);
  }
  const rows = JSON.parse(execFileSync('psql', ['-X', '-q', '-At', PG, '-c', `select json_agg(json_build_object('y', year_from, 'f', file_title, 'l', licence, 'a', author, 's', status, 'w', width, 'sz', sizes, 'src', source_name) order by year_from) from vehicle_stock_photos where make = 'toyota'`], { encoding: 'utf8' }));
  assert.deepEqual(rows.map((r) => [r.y, r.l, r.a, r.s, r.w, r.sz, r.src]), [[2010, 'CC BY-SA 2.0', 'Flickr Tester', 'active', 1280, [640, 1280], 'Flickr via Openverse'],
    [2012, 'CC BY-SA 4.0', 'Tester', 'active', 1280, [640, 1280], 'Wikimedia Commons'], [2018, 'CC BY-SA 4.0', 'Tester', 'active', 1280, [640, 1280], 'Wikimedia Commons']]);
  const page = JSON.parse(execFileSync('psql', ['-X', '-q', '-At', PG, '-c', `select public.vehicle_stock_photo('toyota', 'camry', 2015)`], { encoding: 'utf8' }));
  assert.equal(page.generation, 'Toyota Camry Eighth generation (XV50; 2011)');
  assert.equal(page.match, 'exact');
}
console.log(`offline check passed (${PG ? 'write' : 'dry'}): ${run.picks.length} picks, ${stored.size} files stored, ${deleted.length} deleted`);
