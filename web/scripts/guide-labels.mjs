// The guides' label check (migration 0055): every button or label a guide names in bold ("Press **Approve**") must be
// one the portals show in this commit (web/scripts/portal-facts.mjs). A label that no screen shows any more means the
// section is out of date: the guide upkeep run rewrites it, and this script lists it.
//   node scripts/guide-labels.mjs                   checks docs/guides/content (exit 1 when a label is missing)
//   node scripts/guide-labels.mjs --json file.json  checks sections given as [{portal, slug, title, body_md}] (the live guides)
//   node scripts/guide-labels.mjs --report          lists without failing
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { portalFacts } from './portal-facts.mjs';
import { missingLabels, navPathProblems } from '../src/features/guides/upkeep.ts';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CONTENT = path.resolve(WEB, '../docs/guides/content');

export function checkSections(sections, facts = portalFacts()) {
  const problems = [];
  for (const s of sections) {
    const missing = missingLabels(s.body_md, facts.labels);
    const paths = navPathProblems(s.body_md, facts.nav[s.portal] ?? []);
    if (missing.length || paths.length) problems.push({ portal: s.portal, slug: s.slug, title: s.title, missing, ...(paths.length ? { paths } : {}) });
  }
  return problems;
}

export function committedSections() {
  const out = [];
  for (const portal of ['renter', 'owner', 'admin', 'va', 'field', 'investor']) {
    const g = JSON.parse(fs.readFileSync(path.join(CONTENT, `${portal}.json`), 'utf8'));
    for (const s of g.sections) out.push({ portal, slug: s.slug, title: s.title, body_md: s.body_md });
  }
  return out;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const i = process.argv.indexOf('--json');
  const sections = i > 0 ? JSON.parse(fs.readFileSync(process.argv[i + 1], 'utf8')) : committedSections();
  const problems = checkSections(sections);
  for (const p of problems) console.log(`${p.portal}/${p.slug}: ${[...p.missing.map((m) => `"${m}"`), ...(p.paths ?? []).map((x) => `menu path "${x}"`)].join(', ')}`);
  console.log(`guide labels: ${sections.length} sections checked, ${problems.length} name labels no screen shows`);
  if (problems.length && !process.argv.includes('--report')) process.exit(1);
}
