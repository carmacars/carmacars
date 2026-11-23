#!/usr/bin/env node
// The notification and data map check (r49): every event of the platform (booking states, payments, offers, onboarding,
// hiring, field jobs, tolls, claims, ...) has its email or notice for every portal it touches, and the template of
// each exists in the email catalogue.
//
//   node scripts/check-notification-map.mjs          exits 1 and lists every gap; known gaps are listed, not failing
//   node scripts/check-notification-map.mjs --json
//
// scripts/notification-map.json is the map: event -> { portal: code } (see its _note). The check fails when
//   - a code of the map is in neither emails/catalogue.json nor an insert into notification_catalogue (migrations)
//   - the code's audience (or also_sent_to) is not the portal it is listed for
//   - an email code has no template (templates/<code>.html and .txt)
//   - an event touches no portal, or a portal name is not an audience
//   - a code the database emits (app.emit_event('code', ...) in a migration, web/src or an Edge Function) has no catalogue row
// 'rule:<name>' is an in-app alert of staff_alert_rules (Admins and the people on duty); 'gap: <why>' entries (a portal touched, no message yet) are printed on every run so they are not forgotten.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const AUD = ['renter', 'owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field', 'insurer', 'applicant', 'partner'];
const cat = JSON.parse(readFileSync(join(ROOT, 'emails', 'catalogue.json'), 'utf8'));
const map = JSON.parse(readFileSync(join(ROOT, 'scripts', 'notification-map.json'), 'utf8'));
const walk = (d, ok, out = []) => {
  if (!existsSync(d)) return out;
  for (const e of readdirSync(d, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name === '.next' || e.name.startsWith('.')) continue;
    const p = join(d, e.name);
    if (e.isDirectory()) walk(p, ok, out); else if (ok(e.name)) out.push(p);
  }
  return out;
};

// every code with its audiences: the email catalogue, then the codes inserted into notification_catalogue by migrations
// (in-app notices and the emails of later releases)
const codes = new Map();
for (const e of cat.emails) codes.set(e.code, { aud: new Set([e.audience, ...(e.also_sent_to ?? [])]), email: true });
const sql = walk(join(ROOT, 'supabase', 'migrations'), (n) => n.endsWith('.sql')).map((f) => readFileSync(f, 'utf8')).join('\n');
const tupleRe = new RegExp(`\\(\\s*'([a-z][a-z0-9_]*)'\\s*,\\s*'(${AUD.join('|')})'`, 'g');
for (const m of sql.matchAll(tupleRe)) if (!codes.has(m[1])) codes.set(m[1], { aud: new Set([m[2]]), email: false });

// staff alert rules (in-app alerts to the Admins and the people on duty): migrations that insert into staff_alert_rules
const rules = new Set();
for (const f of walk(join(ROOT, 'supabase', 'migrations'), (n) => n.endsWith('.sql'))) {
  const t = readFileSync(f, 'utf8');
  if (!/staff_alert_rules/.test(t)) continue;
  for (const m of t.matchAll(/\(\s*'([a-z][a-z0-9_]*)'\s*,\s*'[^']{3,120}'\s*,\s*'[A-Za-z ]{3,16}'/g)) rules.add(m[1]);
}

const problems = [];
const gaps = [];
const bad = (what, ref) => problems.push(`${what}: ${ref}`);

for (const [event, portals] of Object.entries(map.events)) {
  const entries = Object.entries(portals);
  if (!entries.length) bad('event touches no portal', event);
  for (const [portal, v] of entries) {
    if (!AUD.includes(portal)) { bad('unknown portal', `${event}: ${portal}`); continue; }
    for (const code of Array.isArray(v) ? v : [v]) {
      if (typeof code === 'string' && code.startsWith('gap:')) { gaps.push(`${event} > ${portal}: ${code.slice(4).trim()}`); continue; }
      if (typeof code === 'string' && code.startsWith('rule:')) {
        if (!rules.has(code.slice(5))) bad('no staff alert rule', `${event} > ${portal}: ${code.slice(5)}`);
        else if (!portal.startsWith('staff_')) bad('a staff alert rule is for staff portals', `${event} > ${portal}: ${code}`);
        continue;
      }
      const c = codes.get(code);
      if (!c) { bad('no catalogue row', `${event} > ${portal}: ${code}`); continue; }
      if (!c.aud.has(portal)) bad('wrong audience', `${event} > ${portal}: ${code} is for ${[...c.aud].join(', ')}`);
    }
  }
}
// the template of every email code
for (const e of cat.emails) {
  for (const f of [`templates/${e.code}.html`, `templates/${e.code}.txt`]) {
    if (!existsSync(join(ROOT, 'emails', f))) bad('template missing', `${e.code}: emails/${f}`);
  }
}
// every code emitted has a catalogue row (a missing row means the event reaches nobody)
const srcFiles = [
  ...walk(join(ROOT, 'supabase', 'migrations'), (n) => n.endsWith('.sql')),
  ...walk(join(ROOT, 'supabase', 'functions'), (n) => /\.(ts|mjs)$/.test(n)),
  ...walk(join(ROOT, 'web', 'src'), (n) => /\.(ts|tsx)$/.test(n) && !/\.test\./.test(n))
];
const emitted = new Map();
for (const f of srcFiles) {
  const t = readFileSync(f, 'utf8');
  for (const m of t.matchAll(/emit_event\(\s*'([a-z][a-z0-9_]*)'/g)) if (!emitted.has(m[1])) emitted.set(m[1], f.replace(ROOT + '/', ''));
}
for (const [code, f] of emitted) if (!codes.has(code)) bad('emitted with no catalogue row', `${code} (${f})`);

const mapped = new Set(Object.values(map.events).flatMap((p) => Object.values(p).flat()));

const unmapped = [...codes].filter(([c, v]) => v.email && !mapped.has(c)).map(([c]) => c);
if (process.argv.includes('--json')) console.log(JSON.stringify({ problems, gaps, unmapped }, null, 1));
else {
  console.log(`notification map: ${Object.keys(map.events).length} events, ${codes.size} codes (${cat.emails.length} emails), ${emitted.size} emitted codes, ${unmapped.length} email codes not in the map (digests, marketing, reminders)`);
  for (const g of gaps) console.log(`  GAP     ${g}`);
  for (const p of problems) console.log(`  FAIL    ${p}`);
}
process.exit(problems.length ? 1 : 0);
