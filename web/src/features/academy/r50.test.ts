// Release 50 in the academy (migration 4200): the funny wrong option of every question, and a picture in every section.
// npm run test:unit. The jokes are placed in the database by a trigger (tested in supabase/tests/99_academy_jokes.sql, which also
// checks that every question there has exactly one joke and the right answer still points at the same option); here: the bank,
// the generated migration, the playful line, and the pictures of every section with their alt text, size and format.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { PICTURE_KINDS, jokeOf, jokeQuip, visualAlt, wrapLabel, type Visual } from './model.ts';

const root = fileURLToPath(new URL('../../../../', import.meta.url));
type Scene = { caption: string; say: string; visual: Visual };
const load = async () => (await import(new URL('../../../../supabase/seed/academy/r50visuals.mjs', import.meta.url).href)) as { VISUALS: Record<string, Scene[]>; ICONS: string[]; LESSON_TITLE: string };
const jokes = JSON.parse(readFileSync(`${root}web/src/features/academy/jokes.json`, 'utf8')) as Array<{ text: string; quip: string }>;
const migrations = `${root}supabase/migrations/`;
const sectionSlugs = (): string[] => {
  const out = new Set<string>();
  for (const f of readdirSync(migrations)) for (const m of readFileSync(migrations + f, 'utf8').matchAll(/insert into academy_sections \(slug[^)]*\) values \('([a-z0-9-]+)'/g)) out.add(m[1]!);
  return [...out];
};

test('4200: the bank of jokes: light, short, different, never a long dash, each with a playful line', () => {
  assert.ok(jokes.length >= 50, `${jokes.length} jokes`);
  assert.equal(new Set(jokes.map((j) => j.text)).size, jokes.length, 'a joke twice');
  for (const j of jokes) {
    assert.ok(j.text.length > 3 && j.text.length <= 60, j.text);
    assert.match(j.quip, /^Nice try\./, j.text);
    assert.doesNotMatch(j.text + j.quip, /[\u2013\u2014\u2018\u2019]/, j.text);
  }
  // light workplace humour about cars, renters, Toronto traffic and coffee: some of each theme, nothing about people
  const all = jokes.map((j) => j.text + ' ' + j.quip).join(' ').toLowerCase();
  for (const w of ['coffee', '401', 'gardiner', 'car', 'renter']) assert.ok(all.includes(w), `no joke about ${w}`);
  assert.doesNotMatch(all, /\b(stupid|idiot|dumb|ugly|fat|gay|race|religio|women|men)\b/);
});

test('4200: the migration carries exactly the bank and the lessons the generator makes', () => {
  const out = execFileSync('node', [`${root}supabase/seed/4200_gen_academy.mjs`, '--check'], { encoding: 'utf8' });
  assert.match(out, /up to date/);
  const sql = readFileSync(`${migrations}4200_r50_academy_jokes_visuals.sql`, 'utf8');
  for (const j of jokes) assert.ok(sql.includes(`'${j.text.replace(/'/g, "''")}'`), j.text);
  // the trigger keeps the right answer on the same option, adds only one joke, never the answer, and the options limit allows it
  assert.match(sql, /create trigger academy_questions_a_joke before insert or update of options, answer on academy_questions/);
  assert.match(sql, /if v_pos <= new\.answer then new\.answer := new\.answer \+ 1; end if;/);
  assert.match(sql, /between 2 and 7/);
  assert.match(sql, /set search_path = public, app, pg_temp/);
  assert.doesNotMatch(sql, /search_path = [^;\n]*pg_temp[^;\n]*,/, 'pg_temp must end the search path');
});

test('4200: a picked joke gets a playful line; a real option gets none', () => {
  const j = jokes[0]!;
  assert.equal(jokeOf(j.text)?.quip, j.quip);
  assert.equal(jokeQuip(j.text), j.quip);
  assert.equal(jokeQuip('Within 5 minutes'), '');
  assert.equal(jokeQuip(undefined), '');
  for (const x of jokes) assert.equal(jokeQuip(x.text), x.quip);
});

test('4200: every section has a See it lesson with at least one picture with alt text', async () => {
  const { VISUALS } = await load();
  const slugs = sectionSlugs();
  assert.ok(slugs.length >= 70, `${slugs.length} sections`);
  for (const s of slugs) {
    const scenes = VISUALS[s];
    assert.ok(scenes && scenes.length > 0, `${s}: no visuals`);
    const pics = scenes.filter((x) => (PICTURE_KINDS as readonly string[]).includes(x.visual.kind));
    assert.ok(pics.length >= 1, `${s}: no picture`);
    for (const p of pics) assert.ok(visualAlt(p.visual).trim().length >= 12, `${s}: ${p.visual.kind} without alt text`);
    for (const sc of scenes) { assert.ok(sc.caption.trim() && sc.say.trim(), `${s}: a scene with no words`); assert.doesNotMatch(JSON.stringify(sc), /[\u2013\u2014]/, `${s}: a long dash`); }
  }
  for (const s of Object.keys(VISUALS)) assert.ok(slugs.includes(s), `${s}: visuals for no section`);
  // and the migration inserts the lesson for each of them
  const sql = readFileSync(`${migrations}4200_r50_academy_jokes_visuals.sql`, 'utf8');
  for (const s of slugs) assert.ok(sql.includes(`where s.slug = '${s}' and not exists`), `${s}: not in the migration`);
});

test('4200: the pictures: webp, about 150 KB or less, in public/academy, sized, with alt text on every image and lazy loading', async () => {
  const { VISUALS, ICONS } = await load();
  const manifest = JSON.parse(readFileSync(`${root}supabase/seed/academy/images.json`, 'utf8')) as Record<string, { w: number; h: number; bytes: number }>;
  const srcs = new Set<string>();
  for (const scenes of Object.values(VISUALS)) for (const { visual: v } of scenes) {
    if (v.kind === 'pic') { srcs.add(v.src); assert.ok(v.w > 0 && v.h > 0, v.src); assert.ok(v.alt.length > 20, v.src); for (const p of v.pins ?? []) { assert.ok(p.label.trim() && p.x >= 0 && p.x <= 100 && p.y >= 0 && p.y <= 100, `${v.src} pin ${p.n}`); } }
    if (v.kind === 'compare') { srcs.add(v.good.src); srcs.add(v.bad.src); assert.ok(v.good.text && v.bad.text); }
    if (v.kind === 'flow') { assert.ok(v.steps.length >= 2 && v.steps.length <= 8); for (const s of v.steps) assert.ok(ICONS.includes(s.icon), s.icon); }
    if (v.kind === 'icons') for (const s of v.items) assert.ok(ICONS.includes(s.icon), s.icon);
    if (v.kind === 'dodont') assert.ok(v.pairs.length >= 1 && v.pairs.every((p) => p.do && p.dont));
  }
  assert.ok(srcs.size >= 30, `${srcs.size} pictures`);
  for (const src of srcs) {
    assert.match(src, /^\/academy\/[\w.-]+\.webp$/);
    const file = `${root}web/public${src}`;
    assert.ok(existsSync(file), src);
    const bytes = statSync(file).size;
    assert.ok(bytes <= 150 * 1024, `${src}: ${bytes} bytes`);
    const head = readFileSync(file).subarray(0, 12);
    assert.equal(head.subarray(0, 4).toString(), 'RIFF', src); assert.equal(head.subarray(8, 12).toString(), 'WEBP', src);
    assert.equal(manifest[src.replace('/academy/', '')]?.bytes, bytes, `${src}: the manifest is out of date`);
  }
  // the components: every image lazy with alt, the flow an SVG with a name, a layout for 320 px
  const tsx = readFileSync(`${root}web/src/features/academy/Visuals.tsx`, 'utf8');
  assert.equal((tsx.match(/<img /g) ?? []).length, (tsx.match(/loading="lazy"/g) ?? []).length);
  assert.equal((tsx.match(/<img /g) ?? []).length, (tsx.match(/<img [^>]*alt=\{/g) ?? []).length);
  assert.match(tsx, /role="img" aria-label=\{v\.alt\}/);
  const css = readFileSync(`${root}web/src/features/academy/academy.css`, 'utf8');
  assert.match(css, /\.ac-stage--vis \{ aspect-ratio: auto/);
  assert.match(css, /\.ac-cmp \{[^}]*grid-template-columns: 1fr;/);
});

test('4200: flow labels wrap to the lines of a step', () => {
  assert.deepEqual(wrapLabel('Check each line beside the notice', 17), ['Check each line', 'beside the notice']);
  assert.deepEqual(wrapLabel('Pay', 17), ['Pay']);
  assert.deepEqual(wrapLabel('', 17), []);
});
