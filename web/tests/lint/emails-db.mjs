// Renders every catalogue email with values the database built (the latest outbox row of each code: the payload
// app.notification_payload() made for a real event, plus what the sender adds, exactly as send-outbox does) and
// checks: every merge variable filled, nothing left as a tag, every link a real route on the site (signed file
// links verify and open), images load, the plain-text version has no markup, from and reply-to follow the rule,
// marketing emails carry the unsubscribe link, and the layout fits at 375 and 640 (screenshots in
// reports/emails/). Then the unsubscribe flow end to end on the local site. Local stack only.
//   BASE_URL=http://localhost:3000 node tests/lint/emails-db.mjs [--test-db postgresql://.../carmacars_test] [--no-shots] [codes...]
// The app database gives the most realistic rows (seeded cars, e2e flows); the database of scripts/test.sh, when
// kept (CARMACARS_TEST_PGURL), has a row for nearly every code. Codes with no row anywhere use the samples.
import { createHmac, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';
import postgres from 'postgres';

// the browsers of this machine when present; otherwise Playwright's own cache (CI caches ~/.cache/ms-playwright)
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const EMAILS = path.resolve(HERE, '../../../emails');
const { render, renderText } = await import(path.join(EMAILS, 'src/engine.mjs'));
const cat = JSON.parse(fs.readFileSync(path.join(EMAILS, 'catalogue.json'), 'utf8'));
const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const SITE = 'https://carmacars.ca';
const argv = process.argv.slice(2);
const opt = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv.splice(i, 2)[1] : null; };
const TEST_DB = opt('--test-db') ?? process.env.EMAILS_TEST_DB ?? null;
const noShots = argv.includes('--no-shots'); const samplesOnly = argv.includes('--samples'); const codes = argv.filter((a) => !a.startsWith('--'));
const OUT = 'reports/emails';
fs.mkdirSync(OUT, { recursive: true });

const env = Object.fromEntries((fs.existsSync('.env.local') ? fs.readFileSync('.env.local', 'utf8') : '').split('\n').map((l) => /^([A-Z_]+)=(\S*)/.exec(l)).filter(Boolean).map((m) => [m[1], m[2]]));
const LINK_KEY = process.env.LINK_SIGNING_KEY ?? env.LINK_SIGNING_KEY ?? '';
const PHOTOS = process.env.NEXT_PUBLIC_VEHICLE_PHOTOS_URL ?? env.NEXT_PUBLIC_VEHICLE_PHOTOS_URL ?? '/_local/vehicle-public';
const app = postgres(process.env.DATABASE_URL ?? env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 2, onnotice: () => {} });
const test = TEST_DB ? postgres(TEST_DB, { max: 2, onnotice: () => {} }) : null;

// The routes the build serves, to tell a page behind sign-in from a missing one.
const rm = JSON.parse(fs.readFileSync('.next/routes-manifest.json', 'utf8'));
const routes = [...rm.staticRoutes, ...rm.dynamicRoutes].map((r) => new RegExp(r.regex));
const redirects = rm.redirects.filter((r) => !r.internal).map((r) => ({ re: new RegExp(r.regex), r }));
const isRoute = (p) => routes.some((re) => re.test(p)) || redirects.some((x) => x.re.test(p));

// ------------------------------------------------------------------ the sender's values (send-outbox senderValues)
const b64url = (b) => Buffer.from(b).toString('base64url');
const signDoc = (k, key) => { const body = b64url(JSON.stringify({ k, key, p: 'doc', exp: Math.floor(Date.now() / 1000) + 7 * 86400 })); return `${SITE}/d/${body}.${createHmac('sha256', LINK_KEY).update(body).digest('base64url')}`; };
async function senderValues(sql, r) {
  const portal = r.code.startsWith('owner_') ? `${SITE}/owner` : r.code.startsWith('investor_') ? `${SITE}/investor/statements` : `${SITE}/account`;
  const out = {
    link_expiry: '7 days', verify_url: `${SITE}/sign-in`, sign_in_url: `${SITE}/sign-in`, reset_url: `${SITE}/reset-password`,
    signed_agreement_url: portal, receipt_url: portal, statement_url: portal, supporting_document_url: portal, invoice_url: `${SITE}/contact`,
    security_device: 'Not recorded', security_event: 'Account change', security_event_at: 'Recently', security_place: 'Not recorded'
  };
  if (r.id && LINK_KEY) {
    const [{ refs }] = await sql`select app.outbox_file_refs(${r.id}::uuid) as refs`;
    for (const [name, ref] of Object.entries(refs ?? {})) out[name] = signDoc(ref.k, ref.key);
  }
  return out;
}

async function latest(sql, code) {
  const [r] = await sql`select o.*, c.template_html as th, c.template_text as tt from notification_outbox o join notification_catalogue c on c.code = o.code
                        where o.code = ${code} and o.payload <> '{}'::jsonb order by (o.status = 'sent') desc, cardinality(o.missing_variables), o.created_at desc limit 1`;
  return r ?? null;
}

const problems = []; const warnings = []; const summary = [];
const bad = (code, what) => problems.push(`${code}: ${what}`);
const warn = (code, what) => warnings.push(`${code}: ${what}`);
const checked = new Map();
async function status(url, src) {
  const key = url + '|' + src;
  if (checked.has(key)) return checked.get(key);
  let v;
  const u = new URL(url);
  if (u.pathname.startsWith('/d/')) {
    const tok = u.pathname.slice(3); const [body, sig] = tok.split('.');
    const ok = sig === createHmac('sha256', LINK_KEY).update(body ?? '').digest('base64url');
    if (!ok) v = 'signature does not verify';
    else if (src !== 'app') v = null; // the record lives in the test database: the signature is what can be checked
    else { const r = await fetch(BASE + u.pathname); v = r.status === 200 ? null : `answers ${r.status}`; }
  } else if (src === 'sample') {
    // sample values carry made-up ids: the path must be a route the site serves (or one it redirects)
    v = isRoute(u.pathname) ? null : 'no route serves this path';
  } else {
    let p = u.pathname + u.search; let r; let hops = 0;
    for (;;) {
      r = await fetch(BASE + p, { redirect: 'manual' });
      const loc = r.headers.get('location');
      if (r.status >= 300 && r.status < 400 && loc && hops++ < 5) {
        const l = new URL(loc, BASE);
        if (l.pathname === '/sign-in' || /\/(no-access|not-an-owner)$/.test(l.pathname)) { v = isRoute(u.pathname) || isRoute(p.split('?')[0]) ? null : `${u.pathname} is behind sign-in but no route serves it`; break; }
        p = l.pathname + l.search; continue;
      }
      v = r.status < 400 ? null : `answers ${r.status}`;
      if (!v && r.status === 200 && !isRoute(p.split('?')[0]) && !/\.(png|jpe?g|webp|svg|ico|txt|xml)$/.test(p)) v = null;
      break;
    }
  }
  checked.set(key, v);
  return v;
}

const browser = noShots ? null : await chromium.launch({ args: ['--no-proxy-server'] });
const page = browser ? await (await browser.newContext({ viewport: { width: 640, height: 900 } })).newPage() : null;
const ALIAS = cat.reply_to_aliases;
for (const e of cat.emails.filter((x) => !codes.length || codes.includes(x.code))) {
  let row = samplesOnly ? null : await latest(app, e.code); let src = 'app';
  if (!row && test && !samplesOnly) { row = await latest(test, e.code); src = 'test'; }
  const th = fs.readFileSync(path.join(EMAILS, e.template_html), 'utf8'); const tt = fs.readFileSync(path.join(EMAILS, e.template_text), 'utf8');
  let values; let subject;
  if (row) {
    values = { ...(await senderValues(src === 'app' ? app : test, row)), ...row.payload };
    if (row.missing_variables?.length) bad(e.code, `the database left variables unfilled: ${row.missing_variables.join(', ')} (outbox ${row.id}, ${src})`);
    if (row.reply_to && row.reply_to !== e.reply_to) bad(e.code, `outbox reply-to ${row.reply_to}, catalogue ${e.reply_to}`);
    if (e.category === 'marketing' && !row.unsubscribe_token && row.status !== 'suppressed') bad(e.code, 'marketing email without an unsubscribe token');
    if (e.category === 'marketing' && row.payload.unsubscribe_url && !/\/unsubscribe\?token=/.test(row.payload.unsubscribe_url)) warn(e.code, `unsubscribe link ${row.payload.unsubscribe_url} (old path; redirected)`);
  } else {
    src = 'sample';
    values = { ...Object.fromEntries([...cat.global_variables, ...e.variables].map((v) => [v.name, v.sample])), ...(await senderValues(app, { code: e.code })) };
  }
  const fromAddr = /<([^>]+)>/.exec(e.from)?.[1] ?? e.from;
  if (!/@carmacars\.ca$/.test(fromAddr) || !/^CarmaCars </.test(e.from)) bad(e.code, `from ${e.from}`);
  const wantReply = e.audience === 'investor' ? ALIAS.investors : e.audience.startsWith('staff_') ? ALIAS.contact : e.audience === 'owner' ? (fromAddr.startsWith('billing@') ? ALIAS.billing : ALIAS.owners) : null;
  if (wantReply && e.reply_to !== wantReply && !(fromAddr.startsWith('billing@') && e.reply_to === ALIAS.billing)) bad(e.code, `reply-to ${e.reply_to}, the rule gives ${wantReply}`);
  if (!Object.values(ALIAS).includes(e.reply_to)) bad(e.code, `reply-to ${e.reply_to} is not one of the aliases`);
  let html, text;
  try { subject = renderText(e.subject, values); html = render(th, values); text = renderText(tt, values); } catch (err) { bad(e.code, `does not render (${src}): ${err.message}`); continue; }
  if (/\{\{|\}\}/.test(html + text + subject)) bad(e.code, 'a merge tag is left in the email');
  if (/[—–]/.test(html.replace(/<style[\s\S]*?<\/style>/g, '') + text + subject)) bad(e.code, 'long dash in the email');
  if (/18122211|Canada Inc/i.test(html + text)) bad(e.code, 'numbered company name');
  if (/\bCarma[ -]Cars\b|\bCarmacars\b(?!\.ca)/.test(text + subject)) bad(e.code, 'brand misspelled');
  for (const v of e.variables) {
    const x = values[v.name];
    if (v.type !== 'boolean' && v.type !== 'list' && (x === '' || x === null || x === undefined) && !new RegExp(`\\{\\{#if ${v.name}\\}\\}`).test(th)) warn(e.code, `${v.name} is empty and not optional in the template`);
  }
  if (e.category === 'marketing') {
    if (!/Unsubscribe/.test(html) || !/unsubscribe/i.test(text)) bad(e.code, 'marketing email without the unsubscribe link');
    if (!values.company_address) bad(e.code, 'marketing email without a mailing address (company_address is empty: set the mailing address in Admin > Settings)');
  }
  if (/<[a-z][^>]*>/i.test(text)) bad(e.code, 'markup in the plain-text version');
  // links and images
  const hrefs = [...html.matchAll(/\bhref="([^"]+)"/g)].map((m) => m[1].replace(/&amp;/g, '&'));
  for (const h of new Set(hrefs)) {
    if (/^mailto:[^@\s]+@[^@\s]+\.[a-z]{2,}(\?.*)?$|^tel:\+?[\d-]{10,16}$/.test(h)) continue;
    if (/^(mailto|tel):/.test(h)) { bad(e.code, `bad ${h}`); continue; }
    if (!h.startsWith(SITE)) { if (!/^https:\/\/(www\.)?(instagram|tiktok|google|maps\.google|search\.google)\./.test(h)) warn(e.code, `external link ${h}`); continue; }
    const why = await status(h, src);
    if (why) bad(e.code, `link ${h.replace(SITE, '')}: ${why}`);
  }
  for (const m of html.matchAll(/<img\b[^>]*>/g)) {
    const s = (/\bsrc="([^"]*)"/.exec(m[0])?.[1] ?? '').replace(/&amp;/g, '&');
    if (!s) { bad(e.code, 'image with an empty src'); continue; }
    const local = s.replace(`${SITE}/media`, BASE + PHOTOS).replace(SITE, BASE);
    if (!local.startsWith(BASE)) continue;
    const r = await fetch(local).catch(() => ({ status: 599 }));
    if (r.status !== 200) bad(e.code, `image ${s} answers ${r.status}`);
    if (!/\balt="/.test(m[0])) bad(e.code, `image without alt ${s}`);
  }
  // looks: 640 and 375
  if (page) {
    for (const w of [640, 375]) {
      await page.setViewportSize({ width: w, height: 900 });
      await page.setContent(html.replaceAll(SITE + '/media', BASE + PHOTOS), { waitUntil: 'load' });
      const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      if (over > 0) bad(e.code, `wider than ${w} by ${over}px`);
      await page.screenshot({ path: `${OUT}/${e.code}.${w}.png`, fullPage: true });
    }
  }
  fs.writeFileSync(`${OUT}/${e.code}.html`, html); fs.writeFileSync(`${OUT}/${e.code}.txt`, `Subject: ${subject}\nFrom: ${e.from}\nReply-To: ${e.reply_to}\n\n${text}`);
  summary.push({ code: e.code, audience: e.audience, source: src, outbox: row?.id ?? null, subject, links: new Set(hrefs).size });
}

// ------------------------------------------------------------------ unsubscribe, end to end on the local site
if (!codes.length || codes.some((c) => cat.emails.find((e) => e.code === c)?.category === 'marketing')) {
  const token = randomUUID(); const to = `unsub-check-${Date.now()}@example.test`;
  await app`insert into notification_outbox (code, category, priority, audience, dedupe_key, to_address, unsubscribe_token, status, status_reason)
            values ('renter_comeback_1w', 'marketing', 5, 'renter', ${'emails-db:' + token}, ${to}, ${token}, 'suppressed', 'emails-db check')`;
  const g1 = await (await fetch(`${BASE}/unsubscribe?token=${token}`)).text();
  if (!/Unsubscribe from offers/.test(g1)) bad('unsubscribe', 'the page does not offer the button');
  const old = await fetch(`${BASE}/email/unsubscribe?token=${token}`, { redirect: 'manual' });
  if (![301, 308].includes(old.status) || !old.headers.get('location')?.includes(`/unsubscribe?token=${token}`)) bad('unsubscribe', `the old path answers ${old.status} to ${old.headers.get('location')}`);
  const post = await fetch(`${BASE}/api/unsubscribe?token=${token}`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'List-Unsubscribe=One-Click' });
  if (post.status !== 200) bad('unsubscribe', `the one-click POST answers ${post.status}`);
  const g2 = await (await fetch(`${BASE}/unsubscribe?token=${token}`)).text();
  if (!/You are unsubscribed/.test(g2)) bad('unsubscribe', 'the page does not say it is done after the one-click POST');
  const [{ n }] = await app`select count(*)::int n from email_suppressions where email = ${to} and scope = 'marketing' and lifted_at is null`;
  if (n !== 1) bad('unsubscribe', 'the address is not on the marketing suppression list');
  const junk = await fetch(`${BASE}/unsubscribe?token=not-a-token`);
  if (junk.status !== 200 || !/does not work/.test(await junk.text())) bad('unsubscribe', 'a bad token does not show the explanation');
}

await browser?.close(); await app.end(); await test?.end();
fs.writeFileSync('reports/emails.json', JSON.stringify({ at: new Date().toISOString(), summary, problems, warnings }, null, 2));
const by = summary.reduce((a, s) => ((a[s.source] = (a[s.source] ?? 0) + 1), a), {});
console.log(`emails: ${summary.length} rendered (${Object.entries(by).map(([k, v]) => `${v} from ${k}`).join(', ')}), ${checked.size} links checked`);
if (warnings.length) console.log('warnings:\n  ' + warnings.join('\n  '));
if (problems.length) { console.log(problems.join('\n')); console.log(`emails: FAILED, ${problems.length} problems`); process.exit(1); }
console.log('emails: 0 problems');
