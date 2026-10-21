#!/usr/bin/env node
// Every change record names the guide chapters it changed, so a feature never ships without its guide (the audit of
// October 21, 2026: the releases 0070 and 0071 reached no guide).
//
//   node scripts/check-change-guides.mjs           checks docs/changes/*.md dated after 2026-10-21 (and 2026-10-21-audit-fixes.md)
//   node scripts/check-change-guides.mjs --all     checks every record (the older ones predate the rule)
//
// A record has a section "## Guides" listing each chapter it changed as `portal/slug` (the slugs of
// docs/guides/content/<portal>.json, for example `admin/fleet-and-listings`), or the words "No guide change" with the
// reason (for example "No guide change: the motion layer changes no screen's steps"). Each slug named must exist.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CHANGES = join(ROOT, 'docs', 'changes');
const CONTENT = join(ROOT, 'docs', 'guides', 'content');
const FROM = '2026-10-21';
const ALSO = new Set(['2026-10-21-audit-fixes.md']);
const all = process.argv.includes('--all');

const slugs = new Set();
for (const f of readdirSync(CONTENT).filter((x) => x.endsWith('.json') && x !== 'images.json')) {
  const d = JSON.parse(readFileSync(join(CONTENT, f), 'utf8'));
  for (const s of d.sections ?? []) slugs.add(`${d.portal ?? f.replace(/\.json$/, '')}/${s.slug}`);
}

const problems = [];
let checked = 0;
for (const f of readdirSync(CHANGES).filter((x) => /^\d{4}-\d{2}-\d{2}-.+\.md$/.test(x)).sort()) {
  if (!all && !(f.slice(0, 10) > FROM || ALSO.has(f))) continue;
  checked++;
  const md = readFileSync(join(CHANGES, f), 'utf8');
  const m = md.match(/^##\s+(?:\d+\.\s+)?Guides\b[^\n]*\n([\s\S]*?)(?=^##\s|(?![\s\S]))/m);
  if (!m) { problems.push(`${f}: no "## Guides" section (list each guide chapter as portal/slug, or write "No guide change" and why)`); continue; }
  const body = m[1];
  const named = [...body.matchAll(/`([a-z]+\/[a-z0-9-]+)`/g)].map((x) => x[1]);
  const none = /no guide change/i.test(body);
  if (!named.length && !none) { problems.push(`${f}: the Guides section names no chapter (\`portal/slug\`) and does not say "No guide change"`); continue; }
  if (none && !/no guide change\s*[:(,-]?\s*\S/i.test(body.replace(/`[^`]*`/g, ''))) problems.push(`${f}: "No guide change" needs the reason after it`);
  for (const s of named) if (!slugs.has(s)) problems.push(`${f}: guide chapter ${s} does not exist in docs/guides/content`);
}

if (problems.length) {
  for (const p of problems) console.error(p);
  console.error(`check-change-guides: ${problems.length} problem(s) in ${checked} change record(s)`);
  process.exit(1);
}
console.log(`check-change-guides: ${checked} change record(s) name their guide chapters`);
