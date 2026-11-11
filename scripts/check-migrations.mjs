#!/usr/bin/env node
// Migrations are history: once a migration is on main it has been (or will be) applied to the live database, and editing it
// changes nothing there while making a fresh database differ from the live one. A fix is a new migration. (r35 engineering
// rules, docs/engineering-rules.md.)
//
//   node scripts/check-migrations.mjs              names, unique numbers, and no migration on main changed or removed
//   MIGRATIONS_BASE=<ref> node scripts/check-migrations.mjs   compare with another ref (default origin/main)
//
// Checks: every file is NNNN_lower_snake.sql; no two share a number; every migration that exists on the base ref exists here
// with the same content. A branch that is behind main (main has newer migrations it has not merged) passes: only files
// present on both sides are compared. Without the base ref (no network, a shallow clone) the history check is skipped
// with a notice, never failed.
import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIR = 'supabase/migrations';
const BASE = process.env.MIGRATIONS_BASE || 'origin/main';
const git = (...a) => execFileSync('git', a, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();

const problems = [];
const files = readdirSync(join(ROOT, DIR)).filter((f) => f.endsWith('.sql')).sort();
const seen = new Map();
for (const f of files) {
  if (!/^\d{4}_[a-z0-9_]+\.sql$/.test(f)) problems.push(`${f}: name must be NNNN_lower_snake.sql`);
  const n = f.slice(0, 4);
  if (seen.has(n)) problems.push(`${f}: number ${n} is also used by ${seen.get(n)}`);
  else seen.set(n, f);
}

let base = null;
try { git('rev-parse', '--verify', '--quiet', `${BASE}^{commit}`); base = BASE; } catch {
  try { git('fetch', '--quiet', '--depth=1', 'origin', 'main'); git('rev-parse', '--verify', '--quiet', 'FETCH_HEAD^{commit}'); base = 'FETCH_HEAD'; } catch { base = null; }
}
let compared = 0;
if (base) {
  const blobs = (ref) => new Map(git('ls-tree', '-r', ref, '--', `${DIR}/`).split('\n').filter(Boolean).map((l) => {
    const [meta, path] = l.split('\t'); return [path, meta.split(' ')[2]];
  }));
  const before = blobs(base);
  const now = new Map(files.map((f) => [`${DIR}/${f}`, git('hash-object', `${DIR}/${f}`)]));
  for (const [path, blob] of before) {
    if (!now.has(path)) { problems.push(`${path}: on ${BASE} but removed or renamed here (an applied migration stays)`); continue; }
    compared++;
    if (now.get(path) !== blob) problems.push(`${path}: changed since ${BASE}; write a new migration instead of editing an applied one`);
  }
} else {
  console.log(`notice: ${BASE} is not available here, so the history check was skipped`);
}

if (problems.length) {
  console.log(problems.join('\n'));
  console.log(`MIGRATIONS CHECK FAILED: ${problems.length} problem(s)`);
  process.exit(1);
}
console.log(`migrations ok: ${files.length} files, ${compared} compared with ${base ?? 'nothing'}`);
