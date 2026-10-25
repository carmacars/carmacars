// The daily queue of the search copy batch (migration 0133, docs/seo-batches.md): app.seo_batch_queue's answer (read by
// .github/workflows/seo-queue.yml through scripts/deploy/sb.sh) becomes seo/queue/latest.json, each item with the facts
// and the same instructions the website's writer had (web/src/features/seo/batch.ts).
//   node --experimental-strip-types --no-warnings scripts/seo-queue.mjs --in rows.json --out ../seo/queue/latest.json [--limit 500]
import fs from 'node:fs';
import path from 'node:path';
import { buildQueue } from '../src/features/seo/batch.ts';

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const rows = JSON.parse(fs.readFileSync(arg('--in'), 'utf8'));
const q = Array.isArray(rows) ? Object.values(rows[0] ?? {})[0] : rows;
if (!q || !Array.isArray(q.items)) { console.error('seo-queue: the database answered no queue'); process.exit(1); }
const limit = Math.max(1, Math.min(5000, Number(arg('--limit', '500')) || 500));
const out = buildQueue(q, limit);
const file = arg('--out', '../seo/queue/latest.json');
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(out, null, 1) + '\n');
const by = out.items.reduce((m, i) => ({ ...m, [i.kind]: (m[i.kind] ?? 0) + 1 }), {});
console.log(`queue: ${out.count} items (${Object.entries(by).map(([k, v]) => `${v} ${k}`).join(', ') || 'none'}); waiting in all: ${JSON.stringify(out.waiting)}`);
