#!/usr/bin/env node
// The places workflow's load step (migration 0095): one region at a time, in the order of place_regions (Ontario
// first), each staged with COPY and put in place by public.server_places_import_apply. Before each region it checks
// the database size: a region that would take the database past Program settings place_db_cap_mb is skipped and
// named (with the projected size) in the run's record and in Admin > Settings > Search. Then
// public.server_places_import_finish links the landing pages, the GTA and the counts.
//
// 0106: each region goes in CHUNK places a transaction (public.server_places_import_apply_chunk: rows, then parents),
// with a pause and a busy check before each transaction (src/lib/import-pace.ts), so the website keeps the database.
//
//   DATABASE_URL=... node scripts/places/load.mjs --in <build out dir> [--run-url <url>] [--bytes-per-place 240]
//                                                 [--chunk 2000] [--pause-ms 500] [--max-active 6]
import fs from 'node:fs';
import path from 'node:path';
import postgres from 'postgres';
import { CSV_COLUMNS } from '../../src/features/places/gazetteer.ts';
import { beforeBatch } from '../../src/lib/import-pace.ts';

const arg = (k, d = null) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const IN = arg('--in', path.join(process.cwd(), '.places-out'));
const bytesPerPlace = Number(arg('--bytes-per-place', '240')); // measured: about 230 bytes a place with its indexes (220 MB a million)
const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL is required'); process.exit(2); }
const summary = JSON.parse(fs.readFileSync(path.join(IN, 'counts.json'), 'utf8'));
const production = process.env.DEPLOY_ENV === 'production' || /supabase\.(co|com)/.test(url);
if (summary.fixture && production) { console.error('refusing to load the test fixture into production'); process.exit(2); }

const sql = postgres(url, { max: 1, onnotice: () => {}, connection: { statement_timeout: 0, application_name: 'carmacars places import' } });
// gentle on the database (0106, src/lib/import-pace.ts): a pause and a busy check before each transaction
const CHUNK = Number(arg('--chunk', '2000'));
const pace = { pauseMs: Number(arg('--pause-ms', '500')), maxActive: Number(arg('--max-active', '6')), log: (l) => console.log(`pace: ${l}`) };
let waited = 0;
const gentle = async () => { const r = await beforeBatch(async () => (await sql`select app.db_busy() as b`)[0].b, pace); waited += r.waitedMs; };
try {
  const order = (await sql`select code from place_regions order by sort_order, code`).map((r) => r.code);
  const regions = summary.regions.sort((a, b) => (order.indexOf(a) + 1 || 999) - (order.indexOf(b) + 1 || 999));
  const [{ id }] = await sql`select public.server_places_import_begin(${regions}, ${['geonames', 'osm', 'census']}, ${arg('--run-url')}) as id`;
  const skipped = {}; const loaded = [];
  for (const rc of regions) {
    const file = path.join(IN, `${rc}.csv`);
    const rows = summary.per_region[rc] ?? 0;
    const [{ b }] = await sql`select public.server_places_budget() as b`;
    const projected = Number(b.db_bytes) + rows * bytesPerPlace;
    if (projected > Number(b.cap_bytes)) {
      skipped[rc] = `skipped: ${rows} places would take the database to about ${Math.round(projected / 1048576)} MB, past the cap of ${Math.round(Number(b.cap_bytes) / 1048576)} MB`;
      console.log(`${rc}: ${skipped[rc]}`);
      continue;
    }
    await gentle();
    await sql`select public.server_places_stage_clear()`;
    const w = await sql.unsafe(`copy places_staging (${CSV_COLUMNS}) from stdin with (format csv)`).writable();
    await new Promise((res, rej) => { fs.createReadStream(file).on('error', rej).pipe(w).on('finish', res).on('error', rej); });
    // 0106: CHUNK places a transaction (rows, then parents), with a pause and a busy check before each
    const n = { added: 0, updated: 0, parents: 0 };
    for (const phase of ['rows', 'parents']) {
      let after = null;
      for (;;) {
        await gentle();
        const [{ c }] = await sql`select public.server_places_import_apply_chunk(${phase}, ${after}, ${CHUNK}) as c`;
        if (c.after === null || c.after === undefined) break;
        after = c.after;
        n.added += Number(c.added); n.updated += Number(c.updated); n.parents += Number(c.parents);
      }
    }
    const [{ r }] = await sql`select public.server_places_import_region_done(${id}, ${rc.endsWith('-') ? null : rc}, ${sql.json(n)}) as r`;
    loaded.push(rc);
    console.log(`${rc}: ${JSON.stringify(r)}`);
  }
  const [{ f }] = await sql`select public.server_places_import_finish(${id}, ${sql.json(skipped)}) as f`;
  const [{ b }] = await sql`select public.server_places_budget() as b`;
  console.log(`loaded ${loaded.length} regions, skipped ${Object.keys(skipped).length}; places table ${Math.round(Number(f.places_bytes) / 1048576)} MB; database ${Math.round(Number(b.db_bytes) / 1048576)} MB of ${Math.round(Number(b.cap_bytes) / 1048576)} MB`);
  console.log(`by country and kind: ${JSON.stringify(f.by_country)}`);
  console.log(`paced: ${CHUNK} places a transaction, ${Math.round(waited / 1000)} s waiting for a quiet database`);
} finally {
  await sql.end();
}
