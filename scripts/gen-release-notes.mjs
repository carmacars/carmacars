#!/usr/bin/env node
// The investor portal's Updates page data (release 29): web/src/features/investor/updates-data.json from the investor
// notes in docs/releases/*.md (format: web/src/features/investor/updates.ts).
//   node scripts/gen-release-notes.mjs           writes the data
//   node scripts/gen-release-notes.mjs --check   exits 1 when the data is out of date
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { forPage, parseNote } from '../web/src/features/investor/updates.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIR = join(ROOT, 'docs', 'releases');
const OUT = join(ROOT, 'web', 'src', 'features', 'investor', 'updates-data.json');

export function readNotes() {
  return readdirSync(DIR).filter((f) => f.endsWith('.md')).sort().map((f) => {
    const n = parseNote(readFileSync(join(DIR, f), 'utf8'), `docs/releases/${f}`);
    if (`${n.release}.md` !== f) throw new Error(`docs/releases/${f}: "release: ${n.release}" must match the file name`);
    return n;
  });
}
export const build = () => JSON.stringify(forPage(readNotes()), null, 1) + '\n';

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const data = build();
  if (process.argv.includes('--check')) {
    if (!existsSync(OUT) || readFileSync(OUT, 'utf8') !== data) { console.error('updates-data.json is out of date: run node scripts/gen-release-notes.mjs'); process.exit(1); }
    console.log('gen-release-notes: updates-data.json up to date');
  } else { writeFileSync(OUT, data); console.log(`gen-release-notes: ${JSON.parse(data).length} releases written`); }
}
