#!/usr/bin/env node
// Builds every email. Node 22, no dependencies.
//
//   node emails/build.mjs
//
// Reads   emails/src/emails/<code>.mjs
// Writes  emails/templates/<code>.html and .txt   merge tags left in, for the application
//         emails/dist/<code>.html and .txt        filled with sample values, for review
//         emails/catalogue.json                   the catalogue, generated from the same files
//         emails/preview/index.html               gallery of the rendered emails
import { readdirSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { render, renderText, usedNames } from './src/engine.mjs';
import { htmlTemplate, textTemplate } from './src/layout.mjs';
import { SAMPLES, AUDIENCE_SAMPLES } from './src/variables.mjs';
import { GLOBALS, GLOBAL_NOTES, BRAND, FROM } from './src/brand.mjs';
import { PATHS, SITE } from './src/links.mjs';

const ROOT = dirname(fileURLToPath(import.meta.url));
const SRC = join(ROOT, 'src', 'emails');
const AUDIENCES = ['renter', 'owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field'];
const AUDIENCE_LABEL = {
  renter: 'Renter', owner: 'Owner', investor: 'Investor', staff_admin: 'Staff: admin', staff_va_finance: 'Staff: VA finance',
  staff_va_fleet: 'Staff: VA fleet', staff_va_cs: 'Staff: VA customer service', staff_va_sales: 'Staff: VA sales', staff_field: 'Staff: field',
};
const REQUIRED = ['code', 'audience', 'trigger', 'timing', 'category', 'subject', 'preheader', 'from', 'body'];

for (const d of ['dist', 'templates', 'preview']) {
  rmSync(join(ROOT, d), { recursive: true, force: true });
  mkdirSync(join(ROOT, d), { recursive: true });
}

const files = readdirSync(SRC).filter((f) => f.endsWith('.mjs') && !f.startsWith('_')).sort();
const errors = [];
const catalogue = [];

function typeOf(name, v) {
  if (Array.isArray(v)) return 'list';
  if (typeof v === 'boolean') return 'boolean';
  if (/_url$/.test(name)) return 'url';
  return 'string';
}
function describe(name, entry, sampleValue) {
  const v = { name, type: typeOf(name, sampleValue), sample: sampleValue };
  if (v.type === 'list' && sampleValue.length) v.fields = [...new Set(sampleValue.flatMap((o) => Object.keys(o)))];
  if (entry && entry.note) v.note = entry.note;
  return v;
}

for (const file of files) {
  const code = file.replace(/\.mjs$/, '');
  try {
    const email = (await import(pathToFileURL(join(SRC, file)).href)).default;
    for (const k of REQUIRED) if (email[k] === undefined || email[k] === '') throw new Error('missing field: ' + k);
    if (email.code !== code) throw new Error(`code "${email.code}" does not match the file name`);
    if (!AUDIENCES.includes(email.audience)) throw new Error('unknown audience: ' + email.audience);
    if (!['transactional', 'marketing'].includes(email.category)) throw new Error('unknown category: ' + email.category);
    if (!Object.values(FROM).includes(email.from)) throw new Error('unknown from address: ' + email.from);
    if (typeof email.digest !== 'boolean') throw new Error('digest must be true or false');
    if (email.body.filter((b) => b.type === 'hero').length !== 1) throw new Error('exactly one hero block is needed');
    const buttons = JSON.stringify(email.body).split('"type":"button"').length - 1;
    if (buttons > 1 && !email.allowButtons) throw new Error('more than one primary button');

    const html = htmlTemplate(email);
    const text = textTemplate(email);

    // Sample values: shared dictionary, then this email's own samples.
    const own = email.sample || {};
    const pool = {};
    for (const [k, v] of Object.entries(SAMPLES)) pool[k] = v.sample;
    Object.assign(pool, GLOBALS, AUDIENCE_SAMPLES[email.audience] || {}, own);
    const used = new Set();
    for (const src of [email.subject, email.preheader, html, text]) for (const n of usedNames(src, pool)) used.add(n);
    const values = {};
    const variables = [];
    for (const name of [...used].sort()) {
      if (!(name in pool)) throw new Error(`no sample value for {{${name}}}. Add it to src/variables.mjs or to this email's "sample".`);
      values[name] = pool[name];
      const note = name in GLOBALS ? { note: GLOBAL_NOTES[name] } : SAMPLES[name];
      variables.push(describe(name, note, pool[name]));
    }
    for (const k of Object.keys(own)) if (!used.has(k)) throw new Error(`sample "${k}" is not used by the template`);

    writeFileSync(join(ROOT, 'templates', code + '.html'), html);
    writeFileSync(join(ROOT, 'templates', code + '.txt'), text);
    writeFileSync(join(ROOT, 'dist', code + '.html'), render(html, values));
    writeFileSync(join(ROOT, 'dist', code + '.txt'), renderText(text, values));

    catalogue.push({
      code,
      audience: email.audience,
      ...(email.also ? { also_sent_to: email.also } : {}),
      category: email.category,
      trigger: email.trigger,
      timing: email.timing,
      digest: email.digest,
      ...(email.digest ? { digest_slot: email.digestSlot || 'next' } : {}),
      ...(email.source ? { source: email.source } : {}),
      from: email.from,
      reply_to: BRAND.replyTo,
      subject: email.subject,
      preheader: email.preheader,
      sample_subject: renderText(email.subject, values).trim(),
      variables,
      template_html: `templates/${code}.html`,
      template_text: `templates/${code}.txt`,
    });
  } catch (e) {
    errors.push(`${code}: ${e.message}`);
  }
}

if (errors.length) {
  console.error('BUILD FAILED\n' + errors.map((e) => '  ' + e).join('\n'));
  process.exit(1);
}

catalogue.sort((a, b) => AUDIENCES.indexOf(a.audience) - AUDIENCES.indexOf(b.audience) || 0);
writeFileSync(join(ROOT, 'catalogue.json'), JSON.stringify({
  generated_by: 'emails/build.mjs. Do not edit by hand; edit emails/src/emails/<code>.mjs and rebuild.',
  reply_to: BRAND.replyTo,
  global_variables: Object.keys(GLOBALS).map((k) => ({ name: k, type: 'string', sample: GLOBALS[k], note: GLOBAL_NOTES[k] })),
  count: catalogue.length,
  emails: catalogue,
}, null, 2) + '\n');

// ---------- preview gallery ----------
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const groups = AUDIENCES.map((a) => ({ a, items: catalogue.filter((e) => e.audience === a) })).filter((g) => g.items.length);
const gallery = `<!DOCTYPE html>
<html lang="en-CA"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>CarmaCars email gallery</title>
<style>
*{box-sizing:border-box}body{margin:0;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;background:#f3f3f3;color:#111}
header{background:#0a0a0a;color:#fff;border-top:4px solid #D90429;padding:28px 32px}
header .wm{font-size:26px;font-weight:700;letter-spacing:-.8px}header p{margin:8px 0 0;color:#c8c8c8;font-size:15px}
nav{background:#fff;border-bottom:1px solid #e4e4e4;padding:12px 32px;position:sticky;top:0;z-index:2;font-size:14px}
nav a{color:#111;margin-right:18px;text-decoration:none;font-weight:700;white-space:nowrap;display:inline-block;padding:4px 0}nav a span{color:#8a8a8a;font-weight:400}
main{padding:8px 32px 60px;max-width:1500px;margin:0 auto}
h2{font-size:22px;letter-spacing:-.4px;margin:36px 0 16px;padding-top:12px;border-top:2px solid #0a0a0a}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:18px}
.c{background:#fff;border:1px solid #e4e4e4;border-radius:4px;overflow:hidden;display:flex;flex-direction:column}
.c .th{display:block;height:230px;overflow:hidden;background:#ededed;border-bottom:1px solid #e4e4e4}
.c .th img{width:100%;display:block}
.c .b{padding:14px 16px 16px;display:flex;flex-direction:column;gap:6px;flex:1}
.code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;color:#D90429}
.sub{font-weight:700;font-size:15px;line-height:21px}
.tr{font-size:13px;line-height:19px;color:#5c5c5c;flex:1}
.tags span{display:inline-block;font-size:11px;letter-spacing:.6px;text-transform:uppercase;font-weight:700;border:1px solid #0a0a0a;padding:2px 6px;margin:0 4px 4px 0;border-radius:2px}
.tags .m{background:#D90429;border-color:#D90429;color:#fff}.tags .d{background:#0a0a0a;color:#fff}
.ln a{font-size:13px;font-weight:700;color:#111;margin-right:12px}
</style></head><body>
<header><div class="wm">CarmaCars</div><p>${catalogue.length} automated emails, rendered with sample values. Built by emails/build.mjs.</p></header>
<nav>${groups.map((g) => `<a href="#${g.a}">${AUDIENCE_LABEL[g.a]} <span>${g.items.length}</span></a>`).join('')}</nav>
<main>
${groups.map((g) => `<h2 id="${g.a}">${AUDIENCE_LABEL[g.a]} (${g.items.length})</h2>
<div class="grid">
${g.items.map((e) => `<div class="c"><a class="th" href="../dist/${e.code}.html"><img loading="lazy" src="../shots/${e.code}.desktop.png" alt="Screenshot of ${e.code}"></a><div class="b">
<div class="code">${e.code}</div><div class="sub">${esc(e.sample_subject)}</div>
<div class="tags">${e.category === 'marketing' ? '<span class="m">Marketing</span>' : '<span>Transactional</span>'}${e.digest ? '<span class="d">Digest</span>' : ''}</div>
<div class="tr">${esc(e.trigger)}</div>
<div class="ln"><a href="../dist/${e.code}.html">HTML</a><a href="../dist/${e.code}.txt">Text</a><a href="../shots/${e.code}.desktop.png">Desktop</a><a href="../shots/${e.code}.phone.png">Phone</a></div>
</div></div>`).join('\n')}
</div>`).join('\n')}
</main></body></html>
`;
writeFileSync(join(ROOT, 'preview', 'index.html'), gallery);

// ---------- README table ----------
const readmePath = join(ROOT, 'README.md');
if (existsSync(readmePath)) {
  const START = '<!-- EMAIL TABLE START -->', END = '<!-- EMAIL TABLE END -->';
  const md = readFileSync(readmePath, 'utf8');
  if (md.includes(START) && md.includes(END)) {
    const cell = (s) => String(s).replace(/\|/g, '/').replace(/\n/g, ' ');
    const table = groups.map((g) => `### ${AUDIENCE_LABEL[g.a]} (${g.items.length})\n\n| Code | Trigger | Timing | Digest | Category |\n| --- | --- | --- | --- | --- |\n` +
      g.items.map((e) => `| \`${e.code}\` | ${cell(e.trigger)} | ${cell(e.timing)} | ${e.digest ? 'Yes' : 'No'} | ${e.category} |`).join('\n')).join('\n\n');
    writeFileSync(readmePath, md.slice(0, md.indexOf(START) + START.length) + '\n' + table + '\n' + md.slice(md.indexOf(END)));
  }
}

const by = {};
for (const e of catalogue) by[e.audience] = (by[e.audience] || 0) + 1;
console.log(`Built ${catalogue.length} emails.`);
for (const a of AUDIENCES) if (by[a]) console.log(`  ${a}: ${by[a]}`);
