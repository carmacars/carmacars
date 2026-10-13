// Rewrites web/wrangler.jsonc in the CI workspace for what the Cloudflare account offers (never committed):
//   node scripts/deploy/wrangler-config.mjs --cache r2|kv|assets --tag d1|kv|none --storage r2-binding|supabase
//        [--kv-id <namespace id>] [--d1-id <database id>]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const file = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../web/wrangler.jsonc');
const arg = (k) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : undefined; };
const cache = arg('cache'), tag = arg('tag'), storage = arg('storage'), kvId = arg('kv-id'), d1Id = arg('d1-id');
const cfg = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\s*\/\/.*$/gm, ''));

for (const c of [cfg, ...Object.values(cfg.env ?? {})]) {
  c.r2_buckets = (c.r2_buckets ?? []).filter((b) =>
    (b.binding === 'NEXT_INC_CACHE_R2_BUCKET' && cache === 'r2') || (b.binding.startsWith('R2_') && storage === 'r2-binding'));
  if (!c.r2_buckets.length) delete c.r2_buckets;
  if (tag === 'd1' && d1Id) for (const d of c.d1_databases ?? []) d.database_id = d1Id;
  else delete c.d1_databases;
  if (cache === 'kv') c.kv_namespaces = [{ binding: 'NEXT_INC_CACHE_KV', id: kvId }, { binding: 'NEXT_TAG_CACHE_KV', id: kvId }];
}
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n');
console.log(`wrangler.jsonc: cache=${cache} tag=${tag} storage=${storage}`);
