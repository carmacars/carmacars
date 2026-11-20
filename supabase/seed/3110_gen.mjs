#!/usr/bin/env node
// The generated blocks of migration 3110 (release 48 CM): the catalogue rows of its emails (from emails/catalogue.json,
// as owner_terms_gen_catalogue.mjs), the academy section Work chats, and the guide chapters it changed (published as
// 3019 does, against GUIDES_BASE, the r48-n head by default). Run after `node emails/build.mjs`:
//   node supabase/seed/3110_gen.mjs           rewrites the blocks
//   node supabase/seed/3110_gen.mjs --check   exits 1 if a block is out of date (needs git)
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderGuide } from '../../web/src/features/guides/markdown.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MIGRATION = join(ROOT, 'supabase', 'migrations', '3110_r48cm_comms.sql');
const q = (v) => (v === null || v === undefined ? 'null' : "'" + String(v).replace(/'/g, "''") + "'");
const arr = (a) => (a && a.length ? 'array[' + a.map(q).join(', ') + ']::text[]' : "'{}'::text[]");

// ---------------------------------------------------------------- the catalogue
const CODES = ['staff_access_restored', 'staff_access_suspended', 'staff_inactivity_warning', 'text_fell_back'];
const cat = JSON.parse(readFileSync(join(ROOT, 'emails', 'catalogue.json'), 'utf8'));
const site = /export const SITE = '([^']+)'/.exec(readFileSync(join(ROOT, 'emails', 'src', 'links.mjs'), 'utf8'))[1];
const globals = cat.global_variables.map((v) => v.name);
function primaryLink(e) {
  const f = join(ROOT, 'emails', e.template_html);
  if (!existsSync(f)) return null;
  for (const m of readFileSync(f, 'utf8').matchAll(/href="([^"]+)"/g)) {
    if (!m[1].startsWith(site)) continue;
    const p = m[1].slice(site.length) || '/';
    if (!['/', '/terms', '/privacy'].includes(p)) return p;
  }
  return null;
}
const rows = CODES.map((code) => {
  const e = cat.emails.find((x) => x.code === code);
  if (!e) throw new Error(`catalogue.json has no ${code}: run node emails/build.mjs`);
  const vars = e.variables.map((v) => {
    const o = { name: v.name, type: v.type };
    if (v.fields) o.fields = v.fields.map((f) => (typeof f === 'string' ? f : f.name));
    if (globals.includes(v.name)) o.global = true;
    return o;
  });
  return '  (' + [q(e.code), q(e.audience), arr(e.also_sent_to), q(e.category), e.digest ? 'true' : 'false', q(e.digest_slot ?? null),
    q(e.from), q(e.reply_to), q(e.subject), q(e.preheader), q(e.timing), q(e.trigger), q(e.source ?? null),
    q(primaryLink(e)), q(JSON.stringify(vars)) + '::jsonb', q(e.template_html), q(e.template_text)].join(', ') + ')';
});
const catalogue = [
  'insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,',
  '    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values',
  rows.join(',\n'),
  'on conflict (code) do update set',
  '  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,',
  '  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,',
  '  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,',
  '  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,',
  '  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,',
  '  in_catalogue = true, updated_at = now();',
  "update notification_catalogue set emitted_by = 'app.text_fall_back (3110)', no_text = true where code = 'text_fell_back';",
  "update notification_catalogue set emitted_by = 'app.staff_suspension_mail (3110)' where code in ('staff_access_suspended', 'staff_access_restored');",
  'select app.notification_catalogue_refresh();'
].join('\n');

// ---------------------------------------------------------------- the academy
const SECTION = { slug: 'work-chats', title: 'Work chats', blurb: 'All work communication happens in the group work chats, never in private messages.',
  guide_refs: ['va/start-here', 'field/start-here'] };
const LESSONS = [{ title: 'Work talk goes in the group', scenes: [
  { caption: 'One place for work', say: 'Every work conversation happens in the group work chats: the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal. Never in private messages.',
    visual: { kind: 'title', heading: 'Work chats only', text: 'Groups, never private messages' } },
  { caption: 'Why', say: 'In the group the whole team sees the question, the answer and the customer details. When someone is off, nothing is lost and nobody waits for one person.',
    visual: { kind: 'list', heading: 'In the group', items: ['Questions and answers', 'Handovers and problems', 'Customer details and bookings', 'Shift changes'] } },
  { caption: 'A private message about work', say: 'If a colleague or an Admin writes to you privately about work, answer in the group so everyone sees it.',
    visual: { kind: 'chat', lines: [{ who: 'colleague', text: '(private) Can you cover the 3 pm handover?' }, { who: 'you', text: 'Answering in the Team group so everyone sees it: yes, I can take the 3 pm handover.' }] } },
  { caption: 'The rule', say: 'Work communication in the group work chats, every time.',
    visual: { kind: 'rule', heading: 'Group work chats only', text: 'Never private messages for work.', tone: 'warn' } }
] }];
const QUESTIONS = [
  { prompt: 'Where does work communication happen?', options: ['In private messages to the person', 'In the group work chats', 'By personal email', 'Wherever is fastest'], answer: 1,
    explain: 'All work communication happens in the group work chats, never in private messages.' },
  { prompt: 'A colleague messages you privately about a handover. What do you do?', options: ['Answer privately', 'Ignore it', 'Answer in the group work chat', 'Call them on your own phone'], answer: 2,
    explain: 'Answer in the group so the whole team sees it.' },
  { prompt: 'Why does work talk go in the group?', options: ['It is faster to type', 'The whole team sees it and nothing is lost when someone is away', 'Admins like long chats', 'Private messages cost money'], answer: 1,
    explain: 'In the group everyone sees the question, the answer and the details, so nobody waits for one person.' },
  { prompt: 'A renter\'s booking details need to reach a colleague. Where do you share them?', options: ['In a private message', 'In the group work chat or the booking in the portal', 'By text from your own phone', 'Nowhere'], answer: 1,
    explain: 'Customer details go in the group work chats or the portal, never in private messages.' },
  { prompt: 'Which chats count as work chats?', options: ['Any chat app', 'The CarmaCars Team and Sales WhatsApp groups and the chats in the portal', 'Private messages with your lead', 'Your personal email'], answer: 1,
    explain: 'The group work chats: the Team and Sales WhatsApp groups, and the chats in the portal.' }
];
const PATHS = ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field', 'admin'];
const sec = `(select id from academy_sections where slug = ${q(SECTION.slug)})`;
const academy = [
  `insert into academy_sections (slug, title, blurb, guide_refs) values (${q(SECTION.slug)}, ${q(SECTION.title)}, ${q(SECTION.blurb)}, ${arr(SECTION.guide_refs)}) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();`,
  ...LESSONS.map((l, i) => `insert into academy_lessons (section_id, sort, title, scenes) values (${sec}, ${i + 1}, ${q(l.title)}, ${q(JSON.stringify(l.scenes))}::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();`),
  ...QUESTIONS.map((x, i) => `insert into academy_questions (section_id, sort, prompt, options, answer, explain) values (${sec}, ${i + 1}, ${q(x.prompt)}, ${q(JSON.stringify(x.options))}::jsonb, ${x.answer}, ${q(x.explain)}) on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();`),
  ...PATHS.map((p) => `insert into academy_path_sections (path_code, section_id, sort) select ${q(p)}, ${sec}, coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = ${q(p)} on conflict (path_code, section_id) do nothing;`)
].join('\n');

// ---------------------------------------------------------------- the guides
const git = (...a) => execFileSync('git', a, { cwd: ROOT, encoding: 'utf8' }).trim();
const BASE = process.env.GUIDES_BASE || git('rev-parse', 'ea9ebca3');
const guideLines = [];
for (const portal of ['admin', 'va', 'field']) {
  const now = JSON.parse(readFileSync(join(ROOT, 'docs', 'guides', 'content', `${portal}.json`), 'utf8'));
  const base = JSON.parse(execFileSync('git', ['show', `${BASE}:docs/guides/content/${portal}.json`], { cwd: ROOT, encoding: 'utf8' }));
  let after = null;
  for (const s of now.sections) {
    const b = base.sections.find((x) => x.slug === s.slug);
    const prev = after; after = s.slug;
    if (b && b.body_md === s.body_md && b.title === s.title && (b.blurb ?? '') === (s.blurb ?? '')) continue;
    const { html, warnings } = renderGuide([{ ...s, id: 'x' }]);
    if (warnings.length) throw new Error(`${portal}/${s.slug}: ${warnings.join('; ')}`);
    guideLines.push(`select app.guide_release_section(${q(portal)}, ${q(s.slug)}, ${q(s.kind)}, ${q(prev)}, ${q(b?.body_md ?? null)}, ${q(s.title)}, ${q(s.blurb)},\n  ${q(s.body_md)},\n  ${q(html.x)});`);
  }
}

// ---------------------------------------------------------------- write
let sql = readFileSync(MIGRATION, 'utf8');
const put = (name, body) => {
  const re = new RegExp(`-- ${name} 3110 START[^\\n]*\\n[\\s\\S]*?-- ${name} 3110 END`);
  if (!re.test(sql)) throw new Error(`no ${name} block in the migration`);
  sql = sql.replace(re, () => `-- ${name} 3110 START (generated by supabase/seed/3110_gen.mjs; do not edit by hand)\n${body}\n-- ${name} 3110 END`);
};
put('ACADEMY', academy);
put('GUIDES', guideLines.join('\n'));
put('CATALOGUE', catalogue);
if (process.argv.includes('--check')) {
  if (sql !== readFileSync(MIGRATION, 'utf8')) { console.error('3110: a generated block is out of date: node supabase/seed/3110_gen.mjs'); process.exit(1); }
  console.log('3110: blocks up to date');
} else {
  writeFileSync(MIGRATION, sql);
  console.log(`3110: ${rows.length} emails, 1 academy section, ${guideLines.length} guide chapters`);
}
