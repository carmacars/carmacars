// The database tests share one database per slice, so two test files that make a fixture with the same label
// (test.mk_user / mk_renter / mk_owner) clash on the user's id. Each label must belong to one file.
import { readdirSync, readFileSync } from 'node:fs';
const dir = 'supabase/tests';
const owner = new Map();
const clashes = [];
for (const f of readdirSync(dir).filter((n) => n.endsWith('.sql')).sort()) {
  for (const m of readFileSync(`${dir}/${f}`, 'utf8').matchAll(/mk_(?:user|renter|owner)\('([a-z0-9_]+)'/g)) {
    const prev = owner.get(m[1]);
    if (prev && prev !== f) clashes.push(`${m[1]}: ${prev} and ${f}`);
    else owner.set(m[1], f);
  }
}
if (clashes.length) { console.error('Test fixture labels used by more than one file (rename one):\n  ' + [...new Set(clashes)].join('\n  ')); process.exit(1); }
console.log(`test fixtures: ${owner.size} labels, each in one file`);
