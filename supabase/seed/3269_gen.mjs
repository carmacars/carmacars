#!/usr/bin/env node
// The generated blocks of migration 3269 (release 48 RW): the catalogue rows of its emails (from emails/catalogue.json,
// as 3113_gen.mjs), the academy section Rewards, the content calendar and your notifications, and the guide chapters it
// changed (published as 3019 does, against GUIDES_BASE, the r48-int head it was cut from by default). Run after
// `node emails/build.mjs`:
//   node supabase/seed/3269_gen.mjs           rewrites the blocks
//   node supabase/seed/3269_gen.mjs --check   exits 1 if a block is out of date (needs git)
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderGuide } from '../../web/src/features/guides/markdown.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MIGRATION = join(ROOT, 'supabase', 'migrations', '3269_r48rw_guides.sql');
const q = (v) => (v === null || v === undefined ? 'null' : "'" + String(v).replace(/'/g, "''") + "'");
const arr = (a) => (a && a.length ? 'array[' + a.map(q).join(', ') + ']::text[]' : "'{}'::text[]");

// ---------------------------------------------------------------- the catalogue
const CODES = ['notify_summary', 'owner_reward_update', 'owner_tracker_alert', 'owner_tracker_weekly', 'staff_reward_update'];
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
  'select app.notification_catalogue_refresh();'
].join('\n');

// ---------------------------------------------------------------- the academy
const SECTION = { slug: 'r48-rewards-calendar-notifications', title: 'Rewards, the content calendar and your notifications',
  blurb: 'Your staff rewards, the monthly content calendar that waits for your approval, and how you choose your notifications.',
  guide_refs: ['va/shared-tools', 'va/content-calendar', 'field/report-rentals-referrals-and-profile'] };
const LESSONS = [
  { title: 'My rewards', scenes: [
    { caption: 'A thank you for the work', say: 'My rewards is on your first page. It shows your discount on your own rentals and the free rental days you earn.',
      visual: { kind: 'title', heading: 'My rewards', text: 'A discount and free rental days' } },
    { caption: 'What you get', say: 'Once your academy and your agreement are done you get 15% off your own rentals. Sales earn 1 free day for every 100 rental days booked. Field earn 1 for every 100 handovers.',
      visual: { kind: 'list', heading: 'From day one', items: ['15% off your own rentals', 'Sales: 1 free day per 100 rental days booked', 'Field: 1 free day per 100 handovers', 'Silver at 50 days in a month: 20% off', 'Gold at 100: 25% off and a bonus day'] } },
    { caption: 'Who gets rental perks', say: 'Rental perks are for in-person staff in Canada. If you work remotely or outside Canada, there are no rental perks on your account.',
      visual: { kind: 'rule', heading: 'In person, in Canada', text: 'Remote and international staff do not get rental perks.', tone: 'warn' } },
    { caption: 'The rules', say: 'You must be the driver. Not on exotic or partner cars. A perk rental never takes a car from a paying renter: pick up within 48 hours of booking. Free days end after 6 months.',
      visual: { kind: 'list', heading: 'Perk rentals', items: ['You are the driver', 'No exotic or partner cars', 'Never blocks a paying renter', 'Free days end after 6 months', 'Frozen while suspended'] } }
  ] },
  { title: 'The content calendar', scenes: [
    { caption: 'A month of posts', say: 'Each month a content calendar is written for the Facebook Page, Instagram and TikTok: reels, carousels, photos and stories with captions, hashtags, times and a music suggestion.',
      visual: { kind: 'title', heading: 'Content calendar', text: 'Marketing > Content calendar' } },
    { caption: 'You decide', say: 'Read each post. Approve it, edit it, reject it with a reason, or regenerate it. Nothing is published until a person approves it.',
      visual: { kind: 'rule', heading: 'Nothing publishes without approval', text: 'Approve, edit, reject or regenerate each post.', tone: 'warn' } },
    { caption: 'After approval', say: 'With Meta connected, photos and reels post to Facebook and Instagram by themselves. Stories, carousels and TikTok are posted by hand: download, post with the caption, paste the link.',
      visual: { kind: 'list', heading: 'Publishing', items: ['Facebook and Instagram: by themselves', 'TikTok, stories, carousels: by hand', 'Paste the link when it is posted', 'Add the results of posts made by hand'] } }
  ] },
  { title: 'Your notifications', scenes: [
    { caption: 'You choose', say: 'On your profile, Notification preferences has a switch for push, email and text for each kind of notification, with quiet hours and a daily or weekly summary.',
      visual: { kind: 'title', heading: 'Notification preferences', text: 'On your profile' } },
    { caption: 'Always on', say: 'Some cannot be switched off: security codes, agreement notices, pay statements, the jobs and shifts assigned to you, and onboarding or suspension notices.',
      visual: { kind: 'list', heading: 'Always sent', items: ['Security and sign-in codes', 'Agreement notices', 'Pay statements', 'Assigned jobs and shifts', 'Onboarding and suspension'] } },
    { caption: 'Renters and owners too', say: 'Renters and owners choose theirs under Account, Notifications. If one asks why they did not get a message, check their choices first.',
      visual: { kind: 'chat', lines: [{ who: 'renter', text: 'I stopped getting the review emails.' }, { who: 'you', text: 'You can turn them back on under Account, Notifications. Booking and return messages always come.' }] } }
  ] }
];
const QUESTIONS = [
  { prompt: 'Who gets staff rental perks?', options: ['Every staff member', 'In-person staff in Canada whose academy and agreement are done', 'Only Admins', 'Only Sales'], answer: 1,
    explain: 'Rental perks are for in-person staff in Canada. Remote and international staff do not get them.' },
  { prompt: 'How long does a free rental day last?', options: ['1 month', '6 months after you earn it', 'Forever', 'Until the end of the year'], answer: 1,
    explain: 'A free day ends 6 months after you earn it.' },
  { prompt: 'A renter has asked for the car on the dates you want for a free-day rental. What happens?', options: ['You get the car', 'The renter is moved', 'Your perk cannot be used on those dates', 'An Admin decides'], answer: 2,
    explain: 'A perk rental never blocks a paying renter.' },
  { prompt: 'When is a post from the content calendar published?', options: ['As soon as it is written', 'Only after a person approves it', 'At the end of the month', 'When an Admin signs in'], answer: 1,
    explain: 'Nothing is published until someone approves it.' },
  { prompt: 'An approved TikTok post is due. What do you do?', options: ['Nothing, it posts by itself', 'Download it, post it by hand with the caption, and paste the link', 'Reject it', 'Email it to the renter'], answer: 1,
    explain: 'TikTok, stories and carousels are posted by hand from the download and the checklist.' },
  { prompt: 'Which notification can you NOT switch off?', options: ['Sales tips', 'Rewards news', 'A job assigned to you', 'The weekly summary'], answer: 2,
    explain: 'Assigned jobs and shifts, security codes, agreement notices and onboarding or suspension notices are always sent.' }
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
const BASE = process.env.GUIDES_BASE || git('rev-parse', '14fb01c0');
const guideLines = [];
for (const portal of ['renter', 'owner', 'investor', 'va', 'field', 'admin']) {
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
  const re = new RegExp(`-- ${name} 3269 START[^\\n]*\\n[\\s\\S]*?-- ${name} 3269 END`);
  if (!re.test(sql)) throw new Error(`no ${name} block in the migration`);
  sql = sql.replace(re, () => `-- ${name} 3269 START (generated by supabase/seed/3269_gen.mjs; do not edit by hand)\n${body}\n-- ${name} 3269 END`);
};
put('ACADEMY', academy);
put('GUIDES', guideLines.join('\n'));
put('CATALOGUE', catalogue);
if (process.argv.includes('--check')) {
  if (sql !== readFileSync(MIGRATION, 'utf8')) { console.error('3269: a generated block is out of date: node supabase/seed/3269_gen.mjs'); process.exit(1); }
  console.log('3269: blocks up to date');
} else {
  writeFileSync(MIGRATION, sql);
  console.log(`3269: ${rows.length} emails, 1 academy section, ${guideLines.length} guide chapters`);
}
