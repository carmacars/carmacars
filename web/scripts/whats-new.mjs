#!/usr/bin/env node
// The "What's new" pop-up's text (release 43; migration 2730): web/src/generated/whats-new.json, built from the release notes in
// ../docs/releases/rNN.md. A note may carry one section per portal, each a list of "- " lines in plain words:
//   ## For staff   ## For owners   ## For renters   ## For investors   ## For partners   ## For admins
// Only releases with a real date (YYYY-MM-DD, not "pending") are written, and only the sections that have items. Pure file
// work: no database is touched at build or deploy. Run by `npm run build` and `npm run dev`; committed so a checkout type-checks.
//   node scripts/whats-new.mjs           writes the JSON
//   node scripts/whats-new.mjs --check   exits 1 when the committed JSON is out of date
import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..');
export const NOTES_DIR = join(WEB, '..', 'docs', 'releases');
export const OUT = join(WEB, 'src', 'generated', 'whats-new.json');
export const SECTIONS = { 'For staff': 'staff', 'For owners': 'owners', 'For renters': 'renters', 'For investors': 'investors', 'For partners': 'partners', 'For admins': 'admins' };
const DASH = /[–—―]/;

/** Plain words: the markdown marks a note may carry (bold, code, links) are dropped. */
export const plain = (s) => s.replace(/\*\*(.+?)\*\*/g, '$1').replace(/`([^`]+)`/g, '$1').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/\s+/g, ' ').trim();

/** One note as a release for the pop-up, or null when it is not dated yet or has no portal section. Throws when malformed. */
export function parseRelease(text, file = 'note') {
  const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(text.replace(/\r\n/g, '\n'));
  if (!m) throw new Error(`${file}: no front matter between --- lines`);
  const head = {};
  for (const line of m[1].split('\n')) {
    const kv = /^([a-z]+):\s*(.*)$/.exec(line);
    if (kv) head[kv[1]] = kv[2].trim();
  }
  for (const k of ['release', 'date', 'summary']) if (!head[k]) throw new Error(`${file}: "${k}" is missing`);
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(head.release)) throw new Error(`${file}: "release: ${head.release}" is not a short plain id`);
  if (head.date !== 'pending' && !/^\d{4}-\d{2}-\d{2}$/.test(head.date)) throw new Error(`${file}: the date is YYYY-MM-DD or "pending"`);
  const sections = {};
  let cur = null;
  for (const line of m[2].split('\n')) {
    const h = /^##\s+(.+?)\s*$/.exec(line);
    if (h) { cur = SECTIONS[h[1]] ?? null; if (cur) sections[cur] ??= []; continue; }
    if (!cur || !line.trim()) continue;
    const it = /^[-*]\s+(.+)$/.exec(line);
    const item = plain(it ? it[1] : line);
    if (DASH.test(item)) throw new Error(`${file}: no long dashes in the copy ("${item.slice(0, 60)}")`);
    if (item) sections[cur].push(item);
  }
  for (const k of Object.keys(sections)) if (!sections[k].length) delete sections[k];
  if (head.date === 'pending' || !Object.keys(sections).length) return null;
  const summary = plain(head.summary);
  if (DASH.test(summary)) throw new Error(`${file}: no long dashes in the summary`);
  return { release: head.release, date: head.date, seq: Number(head.seq ?? 0) || 0, summary, sections };
}

/** The data for a folder of notes: { releases: { rNN: {...} } }, keys in release order. */
export function buildData(dir = NOTES_DIR) {
  const out = [];
  for (const f of readdirSync(dir).filter((n) => /^r\d+[a-z]?\.md$/.test(n)).sort()) {
    const r = parseRelease(readFileSync(join(dir, f), 'utf8'), `docs/releases/${f}`);
    if (!r) continue;
    if (`${r.release}.md` !== f) throw new Error(`docs/releases/${f}: "release: ${r.release}" must match the file name`);
    out.push(r);
  }
  out.sort((a, b) => (a.date === b.date ? a.seq - b.seq : a.date < b.date ? -1 : 1));
  return { releases: Object.fromEntries(out.map(({ release, ...rest }) => [release, rest])) };
}
export const build = (dir) => JSON.stringify(buildData(dir), null, 1) + '\n';

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const data = build();
  if (process.argv.includes('--check')) {
    if (!existsSync(OUT) || readFileSync(OUT, 'utf8') !== data) { console.error('whats-new.json is out of date: run node scripts/whats-new.mjs'); process.exit(1); }
    console.log('whats-new: up to date');
  } else {
    mkdirSync(dirname(OUT), { recursive: true });
    if (!existsSync(OUT) || readFileSync(OUT, 'utf8') !== data) writeFileSync(OUT, data);
    console.log(`whats-new: ${Object.keys(JSON.parse(data).releases).length} release(s) with portal sections`);
  }
}
