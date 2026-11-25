#!/usr/bin/env node
// The two generated blocks of migration 4200 (release 50, the academy):
//  - JOKES: the bank of funny wrong options (web/src/features/academy/jokes.json) as app.academy_joke_bank();
//  - ACADEMY: the "See it" lesson of every section (supabase/seed/academy/r50visuals.mjs), one lesson of picture scenes each.
//   node supabase/seed/4200_gen_academy.mjs           rewrites the blocks in the migration
//  - QUESTION JOKES (4720): each question's own joke (web/src/features/academy/jokes-by-question.json, keyed "<slug>:<sort>",
//    tied to the prompt by md5) as app.academy_question_joke_line() in migration 4720. Regenerating keeps every written line;
//    a question with no line (or whose prompt changed) carries no joke until one is written.
//   node supabase/seed/4200_gen_academy.mjs --check   exits 1 if a block is out of date or a picture or section is missing
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VISUALS, LESSON_TITLE, ICONS } from './academy/r50visuals.mjs';
import { MAX_BYTES, loadManifest } from './academy/r50images.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const file = '4200_r50_academy_jokes_visuals.sql';
const DIR = join(ROOT, 'supabase', 'migrations');
const MIGRATION = join(DIR, file);
const q = (v) => "'" + String(v).replace(/'/g, "''") + "'";
const LONG = /[\u2013\u2014]/;

const jokes = JSON.parse(readFileSync(join(ROOT, 'web', 'src', 'features', 'academy', 'jokes.json'), 'utf8'));
const problems = [];
if (jokes.length < 50) problems.push(`only ${jokes.length} jokes`);
if (new Set(jokes.map((j) => j.text)).size !== jokes.length) problems.push('a joke twice');
for (const j of jokes) {
  if (!j.text || !j.quip) problems.push(`a joke with no text or no playful line: ${JSON.stringify(j)}`);
  if (j.text.length > 60) problems.push(`joke too long (${j.text.length}): ${j.text}`);
  if (LONG.test(j.text + j.quip)) problems.push(`a long dash in a joke: ${j.text}`);
  if (/[\u2018\u2019]/.test(j.text)) problems.push(`a curly quote in a joke: ${j.text}`);
}

// 4720: the jokes written for their own question: light, short, never a long dash or a curly quote, each different
const FILE_QJ = '4720_r50_question_jokes.sql';
const byQ = JSON.parse(readFileSync(join(ROOT, 'web', 'src', 'features', 'academy', 'jokes-by-question.json'), 'utf8'));
const qjTexts = Object.values(byQ).map((v) => v.joke);
if (new Set(qjTexts).size !== qjTexts.length) problems.push('a question joke twice');
for (const [k, v] of Object.entries(byQ)) {
  if (!/^[a-z0-9-]+:[0-9]+$/.test(k)) problems.push(`question joke key ${k}: not <slug>:<sort>`);
  if (!v.prompt || !v.joke) problems.push(`${k}: no prompt or no joke`);
  else {
    if (v.joke.length > 90) problems.push(`${k}: joke too long (${v.joke.length})`);
    if (LONG.test(v.joke) || /[\u2018\u2019]/.test(v.joke)) problems.push(`${k}: a long dash or curly quote`);
  }
}

// every section of the migrations has its visuals, and the visuals name only sections that exist
const slugs = new Set();
for (const f of readdirSync(DIR).sort()) {
  const t = readFileSync(join(DIR, f), 'utf8');
  for (const m of t.matchAll(/insert into academy_sections \(slug[^)]*\) values \('([a-z0-9-]+)'/g)) slugs.add(m[1]);
}
for (const s of slugs) if (!VISUALS[s]?.length) problems.push(`${s}: no visuals`);
for (const s of Object.keys(VISUALS)) if (!slugs.has(s)) problems.push(`${s}: visuals for a section that does not exist`);
const manifest = loadManifest();
const PICTURE = new Set(['pic', 'compare', 'flow', 'dodont', 'icons']);
for (const [slug, scenes] of Object.entries(VISUALS)) {
  if (!scenes.some((s) => PICTURE.has(s.visual.kind))) problems.push(`${slug}: no picture scene`);
  for (const sc of scenes) {
    const v = sc.visual;
    if (!PICTURE.has(v.kind)) problems.push(`${slug}: ${v.kind} is not a picture kind`);
    if (!v.alt || v.alt.trim().length < 12) problems.push(`${slug}: "${v.heading}" has no alt text`);
    if (!sc.say || !sc.caption) problems.push(`${slug}: a scene with no words`);
    if (LONG.test(JSON.stringify(sc))) problems.push(`${slug}: a long dash`);
    for (const st of v.steps ?? []) if (!ICONS.includes(st.icon)) problems.push(`${slug}: no icon ${st.icon}`);
    for (const it of v.items ?? []) if (!ICONS.includes(it.icon)) problems.push(`${slug}: no icon ${it.icon}`);
    if (v.kind === 'flow' && (v.steps.length < 2 || v.steps.length > 8)) problems.push(`${slug}: a flow of ${v.steps.length} steps`);
    const srcs = v.kind === 'pic' ? [v.src] : v.kind === 'compare' ? [v.good.src, v.bad.src] : [];
    for (const src of srcs) {
      const name = src.replace('/academy/', '');
      const m = manifest[name];
      if (!m) problems.push(`${slug}: ${name} is not built (node web/scripts/academy-images.mjs)`);
      else if (m.bytes > MAX_BYTES) problems.push(`${slug}: ${name} is ${m.bytes} bytes`);
      else if (!existsSync(join(ROOT, 'web', 'public', 'academy', name))) problems.push(`${slug}: ${name} is missing from web/public/academy`);
    }
    if (v.kind === 'pic' && !(v.w > 0 && v.h > 0)) problems.push(`${slug}: ${v.src} has no size (build the pictures, then regenerate)`);
  }
}
if (problems.length) { for (const p of problems) console.error(p); process.exit(1); }

const bank = `-- JOKES 4200 START (generated by supabase/seed/4200_gen_academy.mjs from web/src/features/academy/jokes.json; do not edit by hand)
create or replace function app.academy_joke_bank() returns text[]
language sql immutable set search_path = pg_catalog, pg_temp as $$ select array[
${jokes.map((j) => '  ' + q(j.text)).join(',\n')}
]::text[] $$;
-- JOKES 4200 END`;

const lines = [];
for (const [slug, scenes] of Object.entries(VISUALS).sort(([a], [b]) => (a < b ? -1 : 1))) {
  lines.push(`insert into academy_lessons (section_id, sort, title, scenes) select s.id, coalesce((select max(l.sort) from academy_lessons l where l.section_id = s.id), 0) + 1, ${q(LESSON_TITLE)}, ${q(JSON.stringify(scenes))}::jsonb
  from academy_sections s where s.slug = ${q(slug)} and not exists (select 1 from academy_lessons l where l.section_id = s.id and l.title = ${q(LESSON_TITLE)});`);
}
const acad = `-- ACADEMY 4200 START (generated by supabase/seed/4200_gen_academy.mjs from supabase/seed/academy/r50visuals.mjs; do not edit by hand)
${lines.join('\n')}
-- ACADEMY 4200 END`;

const md5 = (t) => createHash('md5').update(t, 'utf8').digest('hex');
const qjRows = Object.entries(byQ).sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => `  (${q(k)}, ${q(md5(v.prompt))}, ${q(v.joke)})`);
const qjBlock = `-- QUESTION JOKES 4720 START (generated by supabase/seed/4200_gen_academy.mjs from web/src/features/academy/jokes-by-question.json; do not edit by hand)
create or replace function app.academy_question_joke_line(p_key text, p_prompt text) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$ select v.j from (values
${qjRows.join(',\n')}
) v(k, m, j) where v.k = p_key and v.m = md5(p_prompt) $$;
-- QUESTION JOKES 4720 END`;
const QJ = join(DIR, FILE_QJ);
const qjSql = readFileSync(QJ, 'utf8');

let sql = readFileSync(MIGRATION, 'utf8');
const swap = (s, start, end, block) => {
  const a = s.indexOf(start), b = s.indexOf(end);
  if (a < 0 || b < 0) throw new Error(`markers missing: ${start}`);
  return s.slice(0, a) + block + s.slice(b + end.length);
};
const next = swap(swap(sql, '-- JOKES 4200 START', '-- JOKES 4200 END', bank), '-- ACADEMY 4200 START', '-- ACADEMY 4200 END', acad);
const qjNext = swap(qjSql, '-- QUESTION JOKES 4720 START', '-- QUESTION JOKES 4720 END', qjBlock);
if (process.argv.includes('--check')) {
  if (next !== sql) { console.error(`${file}: a generated block is out of date`); process.exit(1); }
  if (qjNext !== qjSql) { console.error(`${FILE_QJ}: the question jokes block is out of date`); process.exit(1); }
  console.log(`${FILE_QJ}: ${qjRows.length} question jokes, up to date`);
  console.log(`${file}: ${jokes.length} jokes, ${Object.keys(VISUALS).length} sections of pictures, up to date`);
} else { writeFileSync(MIGRATION, next); writeFileSync(QJ, qjNext); console.log(`${FILE_QJ}: ${qjRows.length} question jokes`); console.log(`${file}: ${jokes.length} jokes, ${Object.keys(VISUALS).length} sections, ${lines.length} lessons`); }
