#!/usr/bin/env node
// Checks the built emails. Run after build.mjs and shots.mjs.
//
//   node emails/check.mjs
//
// Exits 1 if any check fails. Each check prints its own result line.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PATHS, SITE } from './src/links.mjs';

const ROOT = dirname(fileURLToPath(import.meta.url));
const read = (...p) => readFileSync(join(ROOT, ...p), 'utf8');
const cat = JSON.parse(read('catalogue.json'));
const codes = cat.emails.map((e) => e.code);
let failed = 0;
const results = [];
function check(name, problems) {
  const ok = problems.length === 0;
  if (!ok) failed++;
  results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : ` (${problems.length})`}`);
  for (const p of problems.slice(0, 25)) results.push('        ' + p);
}

// Every file we wrote or generated that carries copy.
const outputs = [];
for (const dir of ['dist', 'templates']) for (const f of readdirSync(join(ROOT, dir))) outputs.push([`${dir}/${f}`, read(dir, f)]);
const written = [...outputs, ['catalogue.json', read('catalogue.json')], ['preview/index.html', read('preview', 'index.html')]];
if (existsSync(join(ROOT, 'README.md'))) written.push(['README.md', read('README.md')]);
const walk = (d) => readdirSync(join(ROOT, d), { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));
for (const f of [...walk('src'), 'build.mjs', 'shots.mjs', 'check.mjs']) written.push([f, read(f)]);

// 1. Catalogue entries each have a template and both outputs.
{
  const p = [];
  for (const c of codes) for (const f of [`templates/${c}.html`, `templates/${c}.txt`, `dist/${c}.html`, `dist/${c}.txt`]) if (!existsSync(join(ROOT, f))) p.push('missing ' + f);
  for (const c of codes) if (!existsSync(join(ROOT, 'src', 'emails', c + '.mjs'))) p.push('no source file for ' + c);
  const stray = readdirSync(join(ROOT, 'dist')).filter((f) => !codes.includes(f.replace(/\.(html|txt)$/, '')));
  for (const s of stray) p.push('output with no catalogue entry: dist/' + s);
  if (new Set(codes).size !== codes.length) p.push('duplicate codes');
  check(`every catalogue entry (${codes.length}) has a source file, a template pair and an output pair`, p);
}

// 2. Required catalogue fields.
{
  const p = [];
  const AUD = ['renter', 'owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field', 'insurer', 'applicant'];
  for (const e of cat.emails) {
    for (const k of ['code', 'audience', 'trigger', 'category', 'subject', 'preheader', 'variables', 'from']) if (e[k] === undefined || e[k] === '') p.push(`${e.code}: missing ${k}`);
    if (typeof e.digest !== 'boolean') p.push(`${e.code}: digest is not true or false`);
    if (!AUD.includes(e.audience)) p.push(`${e.code}: audience ${e.audience}`);
    // insurance emails go as Blind Spot Car Rental from its own address (0187); every other email as CarmaCars
    const blindspot = e.from === 'Blind Spot Car Rental <blindspotcarrental@carmacars.ca>';
    if (!blindspot && !/^CarmaCars <(bookings|owners|billing|hello)@carmacars\.ca>$/.test(e.from)) p.push(`${e.code}: from ${e.from}`);
    // Reply-to: the alias of the desk that handles the email (docs/email-aliases.md).
    const A = cat.reply_to_aliases || {};
    if (!Object.values(A).includes(e.reply_to) || !/^[a-z]+@carmacars\.ca$/.test(e.reply_to)) p.push(`${e.code}: reply_to ${e.reply_to} is not a receiving alias`);
    const billingFrom = /<billing@/.test(e.from);
    const want = blindspot ? [A.blindspot]
      : e.audience === 'investor' ? [A.investors]
      : e.audience.startsWith('staff_') ? [A.contact]
      : billingFrom ? [A.billing]
      : e.audience === 'owner' ? [A.owners]
      : /<bookings@/.test(e.from) ? [A.bookings]
      : [A.contact, A.privacy];
    if (!want.includes(e.reply_to)) p.push(`${e.code}: reply_to ${e.reply_to}, expected ${want.join(' or ')}`);
    if (!/^[a-z][a-z0-9_]*$/.test(e.code)) p.push(`${e.code}: code is not snake_case`);
    for (const v of e.variables) if (v.sample === undefined) p.push(`${e.code}: variable ${v.name} has no sample`);
    if (e.digest && !e.audience.startsWith('staff_')) p.push(`${e.code}: digest on a non-staff email`);
  }
  check('catalogue fields are complete and valid', p);
}

// 3. No em dash or en dash (or other dash characters) anywhere.
{
  const p = [];
  const DASH = /[‒–—―−]|&mdash;|&ndash;|&#8211;|&#8212;|&#x2013;|&#x2014;/;
  for (const [f, s] of written) {
    if (f === 'check.mjs') continue;
    s.split('\n').forEach((line, i) => { if (DASH.test(line)) p.push(`${f}:${i + 1}`); });
  }
  check('no em dash or en dash in any output, template, source file, catalogue or README', p);
}

// 4. No hyphen or double hyphen standing in for a dash in the copy.
{
  const p = [];
  for (const [f, s] of outputs) {
    if (!f.endsWith('.txt')) continue;
    s.split('\n').forEach((line, i) => { if (/\S -{1,2} \S/.test(line)) p.push(`${f}:${i + 1}: ${line.trim().slice(0, 80)}`); });
  }
  check('no spaced hyphen used as a dash in the copy', p);
}

// 5. No unfilled merge tag in dist.
{
  const p = [];
  for (const [f, s] of outputs) if (f.startsWith('dist/') && /\{\{|\}\}/.test(s)) p.push(f);
  check('no unfilled {{ in dist', p);
}

// 6. Brand name spelling.
{
  const p = [];
  for (const [f, s] of written) {
    if (f === 'check.mjs') continue;
    const body = s.replace(/[a-z0-9.@-]*carmacars\.ca/gi, '').replace(/carmacars-(platform|staging|prod)/g, '');
    for (const m of body.matchAll(/carma[\s_-]*cars?\b/gi)) if (m[0] !== 'CarmaCars') p.push(`${f}: "${m[0]}"`);
  }
  for (const [f, s] of outputs) {
    if (!f.endsWith('.html')) continue;
    for (const m of s.matchAll(/text-transform:uppercase[^>]*>([^<]*)/g)) if (/carmacars/i.test(m[1])) p.push(`${f}: brand name inside an upper-case label`);
    if ((s.match(/>Carma<span style="color:#D0111B;">Cars<\/span><\/span>/g) || []).length !== 2) p.push(`${f}: wordmark missing from header or footer`);
    if (s.replace(/<[^>]+>/g, '').match(/Carma\s+Cars/)) p.push(`${f}: wordmark splits when tags are stripped`);
  }
  check('CarmaCars is always spelled and capitalised exactly so', p);
}

// 7. Links.
{
  const p = [];
  const allowed = new Set(Object.values(PATHS).map((x) => SITE + x));
  const usedPaths = new Set();
  for (const [f, s] of outputs) {
    if (!f.endsWith('.html')) continue;
    const hrefs = [...s.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
    if ((s.match(/<a\b/g) || []).length !== hrefs.length) p.push(`${f}: an <a> without href`);
    for (const h of hrefs) {
      if (h.trim() === '' || h.trim() === '#') { p.push(`${f}: empty or # href`); continue; }
      if (f.startsWith('templates/')) {
        if (/^\{\{[a-z0-9_]+\}\}$/.test(h)) continue;
        if (allowed.has(h)) { usedPaths.add(h); continue; }
        p.push(`${f}: href not from links.mjs and not a merge variable: ${h}`);
      } else if (!/^https:\/\/[a-z0-9.-]+\//.test(h)) p.push(`${f}: href is not an https URL: ${h}`);
    }
  }
  for (const [f, s] of outputs) {
    if (!f.startsWith('templates/') || !f.endsWith('.txt')) continue;
    for (const m of s.matchAll(/https?:\/\/[^\s)]+/g)) { if (allowed.has(m[0])) usedPaths.add(m[0]); else p.push(`${f}: URL not from links.mjs: ${m[0]}`); }
  }
  check('every href is a merge variable or a path defined in src/links.mjs; none is empty or "#"', p);
  const unused = Object.entries(PATHS).filter(([, x]) => !usedPaths.has(SITE + x)).map(([k]) => k);
  check('every path in src/links.mjs is used by at least one email', unused.map((k) => 'unused: ' + k));
}

// 8. Copy rules.
{
  const p = [];
  const BANNED = [/\bdelv(e|es|ing)\b/i, /\bseamless/i, /\belevat(e|es|ed|ing)\b/i, /\bunlock/i, /\bjourney/i, /thrilled/i, /rest assured/i, /in today'?s world/i,
    /\bnot just\b/i, /\bnot only\b/i, /!/, /\p{Extended_Pictographic}/u, /\bCarma Cars\b/, /\bleverage\b/i, /\bhassle/i, /\bworld-class\b/i, /\bexcited\b/i];
  for (const [f, s] of outputs) {
    if (!f.startsWith('dist/') || !f.endsWith('.txt')) continue;
    for (const re of BANNED) { const m = s.match(re); if (m) p.push(`${f}: "${m[0]}"`); }
    if (/[^\x00-\x7F]/.test(s)) p.push(`${f}: non-ASCII character "${s.match(/[^\x00-\x7F]/)[0]}"`);
  }
  for (const e of cat.emails) for (const k of ['subject', 'preheader', 'sample_subject']) {
    for (const re of BANNED) if (re.test(e[k])) p.push(`${e.code}: ${k} breaks a copy rule`);
    if (/[^\x00-\x7F]/.test(e[k])) p.push(`${e.code}: ${k} has a non-ASCII character`);
  }
  check('copy rules: no banned words, no exclamation marks, no emoji, plain ASCII punctuation', p);
}

// 9. One primary button per rendered email.
{
  const p = [];
  for (const [f, s] of outputs) {
    if (!f.startsWith('dist/') || !f.endsWith('.html')) continue;
    const n = (s.match(/class="btn"/g) || []).length;
    if (n !== 1 && !/renter_vehicle_disabled|renter_breakdown_help|investor_notice_received|renter_signing_code|insurance_staff_message/.test(f)) p.push(`${f}: ${n} primary buttons`);
    if (n > 1) p.push(`${f}: more than one primary button`);
  }
  check('one primary button per rendered email (five emails have none by design: car disabled, breakdown help, investor notice received, the signing code, the insurance message)', p);
}

// 10. Marketing emails carry unsubscribe and the mailing address; transactional ones do not carry unsubscribe.
{
  const p = [];
  for (const e of cat.emails) {
    const h = read('templates', e.code + '.html'); const t = read('templates', e.code + '.txt');
    for (const [kind, s] of [['html', h], ['txt', t]]) {
      if (!s.includes('{{company_address}}')) p.push(`${e.code}.${kind}: no mailing address`);
      // the address line is left out while the address is empty (marketing emails wait for it: migration 0035)
      // an owner billing email names the payee of the pre-authorized debit there (the legal review, 0053)
      const sender = e.audience === 'owner' && /<billing@/.test(e.from) ? '{{payee_name}}' : 'CarmaCars';
      if (!s.includes(kind === 'html' ? `${sender}{{#if company_address}}<br>{{company_address}}` : `${sender}\n{{#if company_address}}{{company_address}}`)) p.push(`${e.code}.${kind}: no sender name above the mailing address`);
      if (/18122211|operated by/i.test(s)) p.push(`${e.code}.${kind}: names the numbered company`);
      if (e.category === 'marketing' && !s.includes('{{unsubscribe_url}}')) p.push(`${e.code}.${kind}: marketing without unsubscribe`);
      if (e.category !== 'marketing' && s.includes('unsubscribe_url')) p.push(`${e.code}.${kind}: transactional with unsubscribe`);
    }
  }
  check('marketing emails carry unsubscribe; every email carries the sender name and mailing address', p);
}

// 11. Investor emails stay neutral.
{
  const p = [];
  const PROMO = [/opportunit/i, /invest more/i, /\bnew investment/i, /\breferral/i, /\brefer (a|your)\b/i, /\bearn/i, /%/, /\bgrow/i, /\bupgrade/i, /\bbonus/i, /top up/i, /friends/i, /\bjoin\b/i];
  for (const e of cat.emails.filter((x) => x.audience === 'investor')) {
    const t = read('dist', e.code + '.txt');
    for (const re of PROMO) { const m = t.match(re); if (m) p.push(`${e.code}: "${m[0]}"`); }
    if (e.category !== 'transactional') p.push(`${e.code}: not transactional`);
    if (!t.includes('not an offer or a solicitation')) p.push(`${e.code}: servicing line missing`);
  }
  check('investor emails are neutral servicing notices with no promotional wording', p);
}

// 12. Screenshots.
{
  const p = [];
  for (const c of codes) for (const k of ['desktop', 'phone']) if (!existsSync(join(ROOT, 'shots', `${c}.${k}.png`))) p.push(`missing shots/${c}.${k}.png`);
  check(`screenshots exist for all ${codes.length} emails, desktop and phone`, p);
}

// 14. Retired and private addresses never appear; the public contact line and socials are in every customer footer.
{
  const p = [];
  for (const [f, s] of written) {
    if (f === 'check.mjs') continue;
    if (/info@carmacars\.ca/.test(s)) p.push(`${f}: info@carmacars.ca`);
    if (/rent@carmacars\.ca/.test(s)) p.push(`${f}: names the private mailbox rent@carmacars.ca`);
  }
  for (const e of cat.emails) {
    if (e.audience.startsWith('staff_')) continue;
    const t = read('dist', e.code + '.txt');
    for (const need of ['contact@carmacars.ca', '289-312-5991', 'Open 24 hours', 'within 2 hours', 'https://instagram.com/carmacars.ca', 'https://tiktok.com/@carmacars.ca']) if (!t.includes(need)) p.push(`${e.code}: footer lacks ${need}`);
  }
  check('no info@ or rent@ anywhere; every customer email carries contact@, the phone, hours, reply time and Instagram and TikTok', p);
}

// 13. Gallery links every email.
{
  const g = read('preview', 'index.html');
  check('preview gallery links every rendered email', codes.filter((c) => !g.includes(`../dist/${c}.html`)).map((c) => 'not linked: ' + c));
}

console.log(results.join('\n'));
console.log(failed ? `\n${failed} CHECK(S) FAILED` : `\nALL ${results.length - results.filter((r) => r.startsWith('   ')).length} CHECKS PASSED`);
process.exit(failed ? 1 : 0);
