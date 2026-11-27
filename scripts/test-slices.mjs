// The release files (99_*) of one database slice, balanced by the seconds each took in the last run.
//   ls 99_*.sql | node scripts/test-slices.mjs <timings.json> <i> <n>     prints slice i of n, one file a line
//   node scripts/test-slices.mjs --merge <timings.json> <timings.tsv>...  prints timings.json updated with the tsv rows
// timings.json: { "99_x.sql": seconds, ... } (supabase/tests/timings.json, refreshed in CI by db-suite through the
// Actions cache). A file with no timing yet counts as the median. Longest first, each to the lightest slice (ties: the
// lower slice), so every slice computes the same split from the same input.
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const load = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return {}; } };

if (args[0] === '--merge') {
  const t = load(args[1]);
  for (const p of args.slice(2)) {
    for (const line of readFileSync(p, 'utf8').split('\n')) {
      const [f, s] = line.split('\t');
      if (f && Number.isFinite(Number(s))) t[f] = Number(s);
    }
  }
  const out = Object.fromEntries(Object.keys(t).sort().map((k) => [k, t[k]]));
  process.stdout.write(JSON.stringify(out, null, 1) + '\n');
} else {
  const [path, iS, nS] = args;
  const i = Number(iS), n = Number(nS);
  if (!(n >= 1 && i >= 1 && i <= n)) { console.error('usage: test-slices.mjs <timings.json> <i> <n>'); process.exit(2); }
  const t = load(path);
  const files = readFileSync(0, 'utf8').split('\n').map((x) => x.trim()).filter(Boolean);
  // a file that still needs another 99_ file's data says so in its first lines ("-- slice-with: 99_x.sql"): the two
  // go to the same slice, and run in name order there (99_r33f_signatures_terms needs 99_r33_fleet_supplier's owner)
  const partner = new Map();
  for (const f of files) {
    let head = '';
    try { head = readFileSync(f, 'utf8').split('\n').slice(0, 5).join('\n'); } catch { /* listed only */ }
    const m = /slice-with: (99_\S+\.sql)/.exec(head);
    if (m && files.includes(m[1])) partner.set(f, m[1]);
  }
  const root = (f) => { let r = f; while (partner.has(r)) r = partner.get(r); return r; };
  const known = files.map((f) => t[f]).filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  const median = known.length ? known[Math.floor(known.length / 2)] : 10;
  const cost = (f) => (Number.isFinite(t[f]) ? t[f] : median);
  const groups = new Map();
  for (const f of files) { const r = root(f); groups.set(r, [...(groups.get(r) ?? []), f]); }
  const gcost = (g) => g.reduce((t, f) => t + cost(f), 0);
  const order = [...groups.values()].sort((a, b) => gcost(b) - gcost(a) || (a[0] < b[0] ? -1 : 1));
  const load_ = Array(n).fill(0), pick = Array.from({ length: n }, () => []);
  for (const g of order) {
    let k = 0;
    for (let j = 1; j < n; j++) if (load_[j] < load_[k]) k = j;
    load_[k] += gcost(g); pick[k].push(...g);
  }
  process.stdout.write(pick[i - 1].sort().join('\n') + (pick[i - 1].length ? '\n' : ''));
}
