// Release 48 in the academy (2990): the worked examples of every role and the path The renter's side; counts and quiz
// integrity, the content generated into the migration, and the pure helpers (guide links, the due date, the screenshot box,
// Ask the guide first). npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dueWords, guideHref, shotSrc } from './model.ts';
import { fitBox, lessonImages } from './video.ts';
import { askGuideFirst } from '../help/routes.ts';

type Quiz = { prompt: string; options: string[]; answer: number; explain: string };
type Scene = { caption: string; say: string; visual: { kind: string; guide?: string; img?: string } };
type Section = { slug: string; title: string; paths: string[]; guides: string[]; lessons: Array<{ title: string; scenes: Scene[] }>; quiz: Quiz[] };
const root = fileURLToPath(new URL('../../../../', import.meta.url));
const load = async () => (await import(new URL('../../../../supabase/seed/academy/r48.mjs', import.meta.url).href)) as { ROLE_SECTIONS: Section[]; RENTER_SECTIONS: Section[]; SECTIONS: Section[] };

test('2990: a section of worked examples for every role, and the nine steps of The renter\'s side', async () => {
  const { ROLE_SECTIONS, RENTER_SECTIONS, SECTIONS } = await load();
  const roles = new Set(ROLE_SECTIONS.flatMap((s) => s.paths));
  for (const r of ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field', 'admin']) assert.ok(roles.has(r), `no worked examples for ${r}`);
  assert.equal(RENTER_SECTIONS.length, 9);
  assert.ok(RENTER_SECTIONS.every((s) => s.paths.length === 1 && s.paths[0] === 'renter_side'));
  assert.equal(SECTIONS.length, 15);
  assert.equal(SECTIONS.reduce((n, s) => n + s.quiz.length, 0), 85);
  // the steps the owner named, each from a renter guide chapter
  const all = JSON.stringify(RENTER_SECTIONS);
  for (const w of ['Request to book', 'Approve and continue', 'Complete your details', 'deposit', 'pink slip', 'OPCF 27', 'Check in yourself', 'Extend', 'I\'ve returned the car', 'Send me a new link']) assert.ok(all.includes(w), w);
});

test('2990: quiz integrity: 5 questions or more, 4 different options, the answer in range, a reason, no question twice', async () => {
  const { SECTIONS } = await load();
  for (const s of SECTIONS) {
    assert.ok(s.quiz.length >= 5, `${s.slug}: ${s.quiz.length} questions`);
    assert.equal(new Set(s.quiz.map((q) => q.prompt)).size, s.quiz.length, `${s.slug}: a question twice`);
    for (const q of s.quiz) {
      assert.equal(q.options.length, 4, `${s.slug}: ${q.prompt}`);
      assert.equal(new Set(q.options).size, 4, `${s.slug}: ${q.prompt}`);
      assert.ok(Number.isInteger(q.answer) && q.answer >= 0 && q.answer < 4, `${s.slug}: ${q.prompt}`);
      assert.ok(q.explain.trim().length > 0, `${s.slug}: ${q.prompt}`);
    }
    assert.doesNotMatch(JSON.stringify(s), /[–—]/, `${s.slug}: a long dash`);
  }
});

test('2990: every screenshot is a guide image of a chapter its section names; every chapter exists', async () => {
  const { SECTIONS } = await load();
  const images = new Set(JSON.parse(readFileSync(`${root}docs/guides/content/images.json`, 'utf8')) as string[]);
  const chapters = new Set<string>();
  for (const p of ['renter', 'admin', 'va', 'field']) for (const c of (JSON.parse(readFileSync(`${root}docs/guides/content/${p}.json`, 'utf8')) as { sections: Array<{ slug: string }> }).sections) chapters.add(`${p}/${c.slug}`);
  let shots = 0;
  for (const s of SECTIONS) {
    for (const g of s.guides) assert.ok(chapters.has(g), `${s.slug}: ${g}`);
    for (const sc of s.lessons.flatMap((l) => l.scenes)) if (sc.visual.kind === 'shot') {
      shots++;
      assert.ok(s.guides.includes(sc.visual.guide!), `${s.slug}: ${sc.visual.guide}`);
      if (sc.visual.img) assert.ok(images.has(sc.visual.img), `${s.slug}: ${sc.visual.img}`);
    }
  }
  assert.ok(shots >= 25, `${shots} screenshots`);
  assert.match(execFileSync('node', ['supabase/seed/2990_gen_academy.mjs', '--check'], { cwd: root, encoding: 'utf8' }), /up to date/);
});

test('2990: guide links for staff and Admins, the screenshot address and its box', () => {
  assert.equal(guideHref('renter/sign-and-pay'), '/staff/guide/renter#sign-and-pay');
  assert.equal(guideHref('va/customer-service'), '/staff/guide#customer-service');
  assert.equal(guideHref('field/a-handover'), '/staff/field/guide#a-handover');
  assert.equal(guideHref('renter/sign-and-pay', true), '/admin/guide/renter#sign-and-pay');
  assert.equal(guideHref('admin/requests-offers-and-bookings', true), '/admin/guide#requests-offers-and-bookings');
  assert.equal(shotSrc('renter-03-offer-desktop-cae88b00.jpg'), '/guides/img/renter-03-offer-desktop-cae88b00.jpg');
  assert.deepEqual(fitBox(1440, 900, 1152, 360), { w: 576, h: 360 });
  assert.deepEqual(fitBox(390, 645, 1152, 400), { w: 242, h: 400 });
  assert.deepEqual(fitBox(0, 0, 10, 10), { w: 0, h: 0 });
  const shot = (img?: string) => ({ caption: 'c', visual: { kind: 'shot' as const, heading: 'h', guide: 'renter/your-offer', ...(img ? { img } : {}) } });
  assert.deepEqual(lessonImages([shot('a.jpg'), shot('a.jpg'), shot(), { caption: 'x', visual: { kind: 'title', heading: 'h' } }]), ['/guides/img/a.jpg']);
});

test('2990: the due date of new sections for staff already working', () => {
  const now = Date.parse('2026-11-14T15:00:00Z');
  assert.match(dueWords('2026-11-21T15:00:00Z', false, now) ?? '', /^New sections to pass by Sat, Nov 21\. After that/);
  assert.equal(dueWords('2026-11-21T15:00:00Z', true, now), null);
  assert.equal(dueWords('2026-11-13T15:00:00Z', false, now), null);
  assert.equal(dueWords(null, false, now), null);
});

test('2990: Ask the guide first names the chapter of the page in every staff portal', () => {
  assert.deepEqual(askGuideFirst('/staff/requests', 'va'), { href: '/staff/guide#customer-service', label: 'the guide, Customer service' });
  assert.equal(askGuideFirst('/admin/bookings/CC-1042', 'admin').href, '/admin/guide#requests-offers-and-bookings');
  assert.equal(askGuideFirst('/staff/field', 'field').href, '/staff/field/guide#my-jobs');
  assert.deepEqual(askGuideFirst('/staff/guide', 'va'), { href: '/staff/guide', label: 'the guide' });
  assert.match(readFileSync(new URL('../assistant/AssistantPanel.tsx', import.meta.url), 'utf8'), /Ask the guide first: <Link/);
});
