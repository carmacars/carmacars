#!/usr/bin/env node
// The addresses workflow's load step (migration 2120): Statistics Canada's Open Database of Addresses into ca_addresses, one
// province at a time in the order given (Ontario first). For each province: the size check (a province that would take the
// database past Program settings place_db_cap_mb is skipped and named), the newest existing row of the province noted, the
// new rows COPY'd in chunks with a pause and a busy check before each (src/lib/import-pace.ts), then the province's older
// rows deleted in id ranges. A re-run replaces a province; nothing is kept twice.
//
//   DATABASE_URL=... node scripts/addresses/load.mjs --in <dir with ODA_XX_v1.csv> --provinces ON,QC,... [--run-url <url>]
//                                                    [--chunk 50000] [--bytes-per-row 150]
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import postgres from 'postgres';
import { COPY_COLUMNS, copyLine, csvLine, headerIndex, odaRow } from '../../src/features/addresses/oda.ts';
import { beforeBatch } from '../../src/lib/import-pace.ts';

const arg = (k, d = null) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const IN = arg('--in', '.');
const provinces = String(arg('--provinces', 'ON')).split(',').map((x) => x.trim().toUpperCase()).filter((x) => /^[A-Z]{2}$/.test(x));
const CHUNK = Number(arg('--chunk', '50000'));
const bytesPerRow = Number(arg('--bytes-per-row', '150')); // the row and its one index: about 150 bytes an address
const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL is required'); process.exit(2); }

const sql = postgres(url, { max: 1, onnotice: () => {}, connection: { statement_timeout: 0, application_name: 'carmacars addresses import' } });
const pace = { pauseMs: Number(arg('--pause-ms', '500')), maxActive: Number(arg('--max-active', '6')), log: (l) => console.log(`pace: ${l}`) };
const gentle = () => beforeBatch(async () => (await sql`select app.db_busy() as b`)[0].b, pace);

/** The CSV of a province: ODA_ON_v1.csv (any case), else the first CSV whose name holds the code. */
function fileOf(p) {
  const names = fs.readdirSync(IN);
  const n = names.find((x) => x.toLowerCase() === `oda_${p.toLowerCase()}_v1.csv`) ?? names.find((x) => x.toLowerCase().endsWith('.csv') && x.toUpperCase().includes(`_${p}_`));
  return n ? path.join(IN, n) : null;
}
async function lines(file) { const n = await new Promise((res) => { let c = 0; fs.createReadStream(file).on('data', (b) => { for (const x of b) if (x === 10) c++; }).on('end', () => res(c)); }); return Math.max(0, n - 1); }

async function copyChunk(buf) {
  if (!buf.length) return;
  await gentle();
  const w = await sql.unsafe(`copy ca_addresses (${COPY_COLUMNS}) from stdin with (format csv)`).writable();
  await new Promise((res, rej) => { w.on('finish', res).on('error', rej); w.end(buf.join('')); });
}

let id = null;
const counts = {}; const skipped = {};
try {
  const [{ b }] = await sql`select public.server_address_import_begin(${provinces}, ${arg('--run-url')}) as b`;
  id = b.id;
  let dbBytes = Number(b.db_bytes);
  for (const p of provinces) {
    const file = fileOf(p);
    if (!file) { skipped[p] = 'no file (the ODA has none for this province, or the download failed)'; console.log(`${p}: ${skipped[p]}`); continue; }
    const rows = await lines(file);
    if (dbBytes + rows * bytesPerRow > Number(b.cap_bytes)) {
      skipped[p] = `skipped: ${rows} addresses would take the database to about ${Math.round((dbBytes + rows * bytesPerRow) / 1048576)} MB, past the cap of ${Math.round(Number(b.cap_bytes) / 1048576)} MB`;
      console.log(`${p}: ${skipped[p]}`);
      continue;
    }
    const [{ m }] = await sql`select public.server_address_province_mark(${p}) as m`;
    const mark = Number(m);
    let header = null; let buf = []; let kept = 0; let dropped = 0;
    for await (const line of readline.createInterface({ input: fs.createReadStream(file, 'utf8'), crlfDelay: Infinity })) {
      if (!line) continue;
      const f = csvLine(line);
      if (!header) { header = headerIndex(f); continue; }
      const r = odaRow(f, header, p);
      if (!r) { dropped++; continue; }
      buf.push(copyLine(r)); kept++;
      if (buf.length >= CHUNK) { await copyChunk(buf); buf = []; }
    }
    await copyChunk(buf);
    // the province's rows from before this run, in id ranges
    let pruned = 0;
    for (let from = 1; mark > 0 && from <= mark; from += CHUNK * 4) {
      await gentle();
      const [{ n }] = await sql`select public.server_address_prune(${p}, ${from}, ${Math.min(mark, from + CHUNK * 4 - 1)}) as n`;
      pruned += Number(n);
    }
    counts[p] = { kept, dropped, replaced: pruned };
    dbBytes += kept * bytesPerRow;
    console.log(`${p}: ${kept} addresses (${dropped} without a street left out, ${pruned} older rows replaced)`);
  }
  await sql`select public.server_address_import_finish(${id}, 'done', ${sql.json(counts)}, ${sql.json(skipped)})`;
  const [{ s }] = await sql`select pg_total_relation_size('ca_addresses') as s`;
  console.log(`loaded ${Object.keys(counts).length} provinces, skipped ${Object.keys(skipped).length}; ca_addresses ${Math.round(Number(s) / 1048576)} MB with its index`);
} catch (e) {
  if (id !== null) await sql`select public.server_address_import_finish(${id}, 'failed', ${sql.json(counts)}, ${sql.json({ ...skipped, error: String(e?.message ?? e).slice(0, 300) })})`.catch(() => {});
  throw e;
} finally {
  await sql.end();
}
