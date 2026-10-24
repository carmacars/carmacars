// The import of the search copy batch (migration 0133, docs/seo-batches.md), in three steps run by
// .github/workflows/seo-import.yml around scripts/deploy/sb.sh (so it works on either database backend):
//   refs   FILES... --dir D   the batch files' items -> D/ctx-NNN.sql (app.seo_batch_context, 100 items a file)
//   check  FILES... --dir D   D/ctx-NNN.json (the live facts) -> the website's checks (web/src/features/seo/batch.ts):
//                             D/publish-NNN.sql (app.seo_batch_publish, 50 items a file) and D/check.json
//   report --dir D            D/check.json and D/published-NNN.json -> notices: published and rejected, with reasons
import fs from 'node:fs';
import path from 'node:path';
import { checkBatch, refsOf } from '../src/features/seo/batch.ts';

const [cmd, ...rest] = process.argv.slice(2);
const di = rest.indexOf('--dir');
const dir = di >= 0 ? rest[di + 1] : 'seo-import';
const files = rest.filter((x, i) => !(i === di || i === di + 1)).filter((f) => f.endsWith('.json'));
fs.mkdirSync(dir, { recursive: true });
const q = (s) => `'${s.replace(/'/g, "''")}'`;
const pad = (n) => String(n).padStart(3, '0');
const chunks = (a, n) => Array.from({ length: Math.ceil(a.length / n) }, (_, i) => a.slice(i * n, (i + 1) * n));
const notice = (title, msg) => console.log(`::notice title=${title}::${String(msg).replace(/\r?\n/g, ' ').slice(0, 900)}`);
const warn = (title, msg) => console.log(`::warning title=${title}::${String(msg).replace(/\r?\n/g, ' ').slice(0, 900)}`);

function items() {
  const all = [];
  for (const f of files) {
    let d;
    try { d = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { warn('seo import', `${f}: not JSON (${e.message})`); continue; }
    const list = Array.isArray(d) ? d : Array.isArray(d?.items) ? d.items : null;
    if (!list) { warn('seo import', `${f}: no "items" list`); continue; }
    list.forEach((it, i) => all.push({ file: f, n: i, batch: Array.isArray(d) ? path.basename(f) : String(d.batch ?? path.basename(f)), it }));
  }
  return all;
}

if (cmd === 'refs') {
  const all = items();
  chunks(all, 100).forEach((c, i) => fs.writeFileSync(path.join(dir, `ctx-${pad(i + 1)}.sql`), `select app.seo_batch_context(${q(JSON.stringify(refsOf(c.map((x) => x.it))))}::jsonb) as c`));
  console.log(`seo import: ${all.length} items in ${files.length} file(s)`);
} else if (cmd === 'check') {
  const all = items();
  const live = []; let ctx = {};
  chunks(all, 100).forEach((_, i) => {
    const rows = JSON.parse(fs.readFileSync(path.join(dir, `ctx-${pad(i + 1)}.json`), 'utf8'));
    const c = Array.isArray(rows) ? rows[0]?.c : rows.c ?? rows;
    live.push(...(c?.items ?? []));
    ctx = { banned: c?.banned ?? [], similarity_max_bps: c?.similarity_max_bps, city: c?.city };
  });
  const res = checkBatch(all.map((x) => x.it), live, ctx);
  const pass = res.flatMap((r, i) => (r.ok ? [{ ...r.publish, from: `${all[i].file}#${all[i].n}` }] : []));
  chunks(pass, 50).forEach((c, i) => fs.writeFileSync(path.join(dir, `publish-${pad(i + 1)}.sql`),
    `select app.seo_batch_publish(${q(JSON.stringify({ batch: [...new Set(all.map((x) => x.batch))].join(', ').slice(0, 200), items: c }))}::jsonb) as r`));
  const report = res.map((r, i) => ({ file: all[i].file, n: all[i].n, kind: r.kind ?? null, id: r.id ?? null, url: r.url ?? null, ok: r.ok, problems: r.ok ? [] : r.problems }));
  fs.writeFileSync(path.join(dir, 'check.json'), JSON.stringify(report, null, 1));
  console.log(`seo import: ${pass.length} of ${res.length} passed the checks`);
} else if (cmd === 'report') {
  const report = JSON.parse(fs.readFileSync(path.join(dir, 'check.json'), 'utf8'));
  const db = fs.readdirSync(dir).filter((f) => /^published-\d+\.json$/.test(f)).sort()
    .flatMap((f) => { const rows = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); return (Array.isArray(rows) ? rows[0]?.r : rows.r)?.results ?? []; });
  const published = db.filter((r) => r.status === 'published');
  const refusedByDb = db.filter((r) => r.status !== 'published');
  const rejected = report.filter((r) => !r.ok);
  for (const r of rejected) warn('seo rejected', `${r.url ?? `${r.kind}:${r.id}`} (${r.file} item ${r.n}): ${r.problems.join('; ')}`);
  for (const r of refusedByDb) warn('seo rejected', `${r.url ?? `${r.kind}:${r.id}`} (by the database): ${(r.problems ?? []).join('; ')}`);
  notice('seo import', `published ${published.length}, rejected ${rejected.length + refusedByDb.length} of ${report.length}${published.length ? `: ${published.slice(0, 20).map((r) => r.url ?? r.id).join(', ')}${published.length > 20 ? ', ...' : ''}` : ''}`);
  fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify({ published, rejected: [...rejected, ...refusedByDb] }, null, 1));
} else {
  console.error('usage: seo-import.mjs refs|check FILES... --dir D | report --dir D');
  process.exit(2);
}
