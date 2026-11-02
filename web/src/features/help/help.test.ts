// "Stuck?" help (migration 0510): every page of the site has an entry in the help map, every chapter and Academy section it
// names exists, checkout, payment and signing steps are off; and the stuck detector's three signs. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { HELP_ROWS, helpFor, helpRow } from './routes.ts';
import { StuckDetector, pageName, stuckOptions } from './stuck.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');
const APP = join(ROOT, 'web', 'src', 'app');

function routes(dir: string, base = ''): string[] {
  const out: string[] = [];
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) { if (f !== 'api') out.push(...routes(p, `${base}/${f}`)); } else if (f === 'page.tsx') out.push(base.replace(/\/\([^)]+\)/g, '') || '/');
  }
  return out;
}
const portalOf: Record<string, string> = { admin: 'admin', va: 'va', field: 'field', owner: 'owner', renter: 'renter', investor: 'investor' };
const chapters = new Map<string, Set<string>>();
for (const p of Object.keys(portalOf)) {
  const d = JSON.parse(readFileSync(join(ROOT, 'docs', 'guides', 'content', `${p}.json`), 'utf8')) as { sections: Array<{ slug: string }> };
  chapters.set(p, new Set(d.sections.map((s) => s.slug)));
}
// the Academy's sections and paths: the seed (0208) and the sections added by later migrations
const seed = ['roles.mjs', 'policies.mjs'].map((f) => readFileSync(join(ROOT, 'supabase', 'seed', 'academy', f), 'utf8')).join('\n');
const mig = readdirSync(join(ROOT, 'supabase', 'migrations')).filter((f) => f >= '0209').map((f) => readFileSync(join(ROOT, 'supabase', 'migrations', f), 'utf8')).join('\n');
const sections = new Set([...seed.matchAll(/slug: '([a-z0-9-]+)'/g), ...mig.matchAll(/insert into academy_sections \(slug[^']*'([a-z0-9-]+)'/g)].map((m) => m[1]!));
const paths = new Set(['cs', 'sales_in_person', 'sales_remote', 'field', 'finance', 'fleet', 'admin']);

test('every page under web/src/app has a help entry (or is marked off)', () => {
  const all = routes(APP);
  assert.ok(all.length > 250, `found ${all.length} pages`);
  const missing = all.filter((r) => !helpRow(r));
  assert.deepEqual(missing, [], `pages with no help entry: ${missing.join(', ')}`);
});

test('every portal page has a guide chapter that exists, and a lesson that exists where named', () => {
  for (const r of routes(APP)) {
    const h = helpRow(r)!;
    if ('off' in h.row) continue;
    const rows = [h.row, ...Object.values(h.row.tabs ?? {})];
    for (const e of rows) {
      assert.ok(chapters.get(e.portal)?.has(e.guide), `${r}: chapter ${e.portal}/${e.guide} is not in docs/guides/content`);
      if (e.lesson) {
        const [p, s] = e.lesson.split('/');
        assert.ok(paths.has(p!), `${r}: Academy path ${p}`);
        assert.ok(sections.has(s!), `${r}: Academy section ${s}`);
      }
    }
  }
  for (const r of HELP_ROWS) if (!('off' in r.row)) assert.ok(r.key[0] !== undefined);
});

test('the portals are the right guides; public, payment and signing pages are off', () => {
  assert.equal(helpFor('/admin/bookings/CC-1042')?.portal, 'admin');
  assert.equal(helpFor('/admin/bookings/CC-1042')?.guideHref, '/admin/guide#requests-offers-and-bookings');
  assert.equal(helpFor('/staff/marketing')?.guide, 'marketing-on-facebook-marketplace');
  assert.equal(helpFor('/staff/marketing')?.lessonHref, '/staff/academy/sales_remote/marketplace-with-claude');
  assert.equal(helpFor('/staff/field/jobs/3f2a9c1e-0000-4000-8000-000000000001')?.portal, 'field');
  assert.equal(helpFor('/staff/field/jobs/3f2a9c1e-0000-4000-8000-000000000001')?.pattern, '/staff/field/jobs/[id]');
  assert.equal(helpFor('/admin/settings')?.lessonHref, '/admin/academy/learn/admin/admin-decisions');
  assert.equal(helpFor('/owner/vehicles')?.lessonHref, null);
  assert.equal(helpFor('/admin/money', 'refunds')?.guide, 'owner-money');
  for (const off of ['/', '/cars/kia-k5', '/pay/abc', '/account/bookings/CC-1/pay', '/account/bookings/CC-1/offer', '/account/bookings/CC-1/sign', '/owner/sign',
    '/investor/sign/x', '/staff/sign', '/staff/field/jobs/x/sign-now', '/admin/bookings/CC-1/sign-now', '/staff/guide', '/sign/agreement']) assert.equal(helpFor(off), null, off);
});

const O = { idleMs: 180_000, errors: 3 };
test('idle: active without success for the whole window fires once; reading alone never does', () => {
  const a = new StuckDetector(O, 0);
  assert.equal(a.check(400_000), null, 'only reading');
  a.activity(10_000); a.activity(100_000);
  assert.equal(a.check(170_000), null);
  assert.equal(a.check(181_000), 'idle');
  assert.equal(a.check(200_000), null, 'once');
  a.progress(210_000); a.activity(220_000);
  assert.equal(a.check(300_000), null, 'a success starts over');
  assert.equal(a.check(391_000), 'idle');
  const gone = new StuckDetector(O, 0);
  gone.activity(1_000);
  assert.equal(gone.check(500_000), null, 'walked away: no prompt');
});

test('errors and back and forth', () => {
  const e = new StuckDetector(O, 0);
  e.error(1_000); e.error(1_100);
  e.error(5_000);
  assert.equal(e.check(5_001), null, 'one attempt reported twice counts once');
  e.error(9_000);
  assert.equal(e.check(9_001), 'errors');
  const l = new StuckDetector(O, 0);
  for (const [i, s] of ['?step=1', '?step=2', '?step=2', '?step=1'].entries()) l.step(s, i);
  assert.equal(l.check(10), null, 'one round trip');
  l.step('?step=2', 11);
  assert.equal(l.check(12), 'loop');
  const fwd = new StuckDetector(O, 0);
  for (const [i, s] of ['a', 'b', 'c', 'd', 'e'].entries()) fwd.step(s, i);
  assert.equal(fwd.check(10), null, 'moving forward is progress enough');
});

test('settings, the test override and the page name', () => {
  assert.deepEqual(stuckOptions(null), { on: true, idleMs: 180_000, errors: 3 });
  assert.deepEqual(stuckOptions({ on: false, idle_minutes: 5, errors: 4 }), { on: false, idleMs: 300_000, errors: 4 });
  assert.equal(stuckOptions({ idle_minutes: 3 }, 1500).idleMs, 1500);
  assert.equal(pageName('Marketing | CarmaCars'), 'Marketing');
  assert.equal(pageName(''), 'this page');
});
