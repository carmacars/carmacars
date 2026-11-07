#!/usr/bin/env node
// Every change record belongs to one release's investor note, so every release adds its section to the investor
// portal's Updates page (release 29). Also: each note is well formed, names only records that exist, says nothing on
// the deny list (web/src/features/investor/updates.ts DENY), and updates-data.json is up to date. Run by check-text.sh.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { denyHits } from '../web/src/features/investor/updates.ts';
import { build, readNotes } from './gen-release-notes.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const problems = [];
let notes = [];
try { notes = readNotes(); } catch (e) { problems.push(e.message); }
const records = new Set(readdirSync(join(ROOT, 'docs', 'changes')).filter((f) => f.endsWith('.md')));
const owner = new Map();
for (const n of notes) {
  for (const c of n.changes) {
    if (!records.has(c)) problems.push(`docs/releases/${n.release}.md names ${c}, which is not in docs/changes`);
    else if (owner.has(c)) problems.push(`${c} is in two releases: ${owner.get(c)} and ${n.release}`);
    else owner.set(c, n.release);
  }
  const text = [n.title, n.summary, ...n.areas.flatMap((a) => a.items)].join('\n');
  for (const [w, why] of denyHits(text)) problems.push(`docs/releases/${n.release}.md: "${w}" (${why}) is not for investors`);
}
for (const r of [...records].sort()) if (!owner.has(r)) problems.push(`docs/changes/${r} belongs to no release: add it to its note in docs/releases (changes:) with its items`);
try { if (problems.length === 0 && readFileSync(join(ROOT, 'web', 'src', 'features', 'investor', 'updates-data.json'), 'utf8') !== build()) problems.push('updates-data.json is out of date: run node scripts/gen-release-notes.mjs'); }
catch { problems.push('updates-data.json is missing: run node scripts/gen-release-notes.mjs'); }
if (problems.length) { console.error(problems.join('\n')); console.error(`check-release-notes: ${problems.length} problem(s)`); process.exit(1); }
console.log(`check-release-notes: ${records.size} change records in ${notes.length} releases`);
