// The deploy and backup shell rules (0320, 0321): which logical backups are kept (scripts/backup/keep.sh) and the owner-step
// annotation of every deploy (scripts/deploy/owner-steps.sh, offline: no database).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '../../..');
const run = (script: string, args: string[], env: Record<string, string> = {}) =>
  execFileSync('bash', [join(ROOT, script), ...args], { encoding: 'utf8', env: { ...process.env, CF_EMAIL_BINDING: '', OWNER_STEPS_JSON: '', FEE_AUDIT_JSON: '', OUTBOX_STALE_JSON: '', GITHUB_STEP_SUMMARY: '', ...env } });

test('logical backups: the last 7 nights and the Sundays of the last 4 weeks', () => {
  const out = run('scripts/backup/keep.sh', ['--now', '2026-11-01T07:30Z', '--days', '7', '--weeks', '4',
    '2026-10-31T0723Z', '2026-10-26T0723Z', '2026-10-25T0723Z', '2026-10-24T0723Z', '2026-10-18T0723Z', '2026-10-11T0723Z', '2026-10-04T0723Z', '2026-09-27T0723Z', 'not-a-stamp']);
  assert.equal(out.trim(), ['keep 2026-10-31T0723Z', 'keep 2026-10-26T0723Z', 'keep 2026-10-25T0723Z', 'drop 2026-10-24T0723Z', 'keep 2026-10-18T0723Z',
    'keep 2026-10-11T0723Z', 'drop 2026-10-04T0723Z', 'drop 2026-09-27T0723Z', 'keep not-a-stamp'].join('\n'));
});

test('owner steps: every waiting feature in one annotation, the Cloudflare email binding included until CF_EMAIL_BINDING is 1', () => {
  const rows = JSON.stringify([{ key: 'meta', feature: 'Posting to Facebook', step: 'Admin > Settings > Meta publishing: enter the Page token.' }]);
  const waiting = run('scripts/deploy/owner-steps.sh', ['--offline'], { OWNER_STEPS_JSON: rows, CF_EMAIL_BINDING: '' });
  assert.match(waiting, /^::warning title=owner steps \(2 waiting\)::- Posting to Facebook: Admin > Settings > Meta publishing/);
  assert.match(waiting, /CF_EMAIL_BINDING = 1/);
  const set = run('scripts/deploy/owner-steps.sh', ['--offline'], { OWNER_STEPS_JSON: '[]', CF_EMAIL_BINDING: '1' });
  assert.equal(set.trim(), '::notice title=owner steps::nothing is waiting on an owner step');
});

test('the fee check: one annotation, owners by reference, each invoice that does not match with why', () => {
  const ok = JSON.stringify({ month: 'November 2026', invoices: 2, owners: 1, total: '$1,073.50', by_owner: [{ owner: 'owner a1b2c3', invoices: 2, total: '$1,073.50' }], problems: [] });
  assert.equal(run('scripts/deploy/fee-audit.sh', ['--offline'], { FEE_AUDIT_JSON: ok }).trim(),
    '::notice title=fee check::November 2026: 2 invoices to 1 owners, $1,073.50. Every invoice matches the agreement.%0A- owner a1b2c3: 2 invoices, $1,073.50');
  const bad = JSON.stringify({ month: 'November 2026', invoices: 3, owners: 1, total: '$1,610.25', by_owner: [{ owner: 'owner a1b2c3', invoices: 3, total: '$1,610.25' }],
    problems: [{ owner: 'owner a1b2c3', invoice: 'INV-1050', car: 'F-12', total: '$536.75', problem: 'every day on a flat monthly payment: no monthly fee' }] });
  const out = run('scripts/deploy/fee-audit.sh', ['--offline'], { FEE_AUDIT_JSON: bad });
  assert.match(out, /^::warning title=fee check \(1 to look at\)::November 2026: 3 invoices to 1 owners, \$1,610\.25\. 1 do not match/);
  assert.match(out, /INV-1050 \(car F-12, owner a1b2c3\), \$536\.75: every day on a flat monthly payment: no monthly fee/);
  assert.match(run('scripts/deploy/fee-audit.sh', ['--offline'], { FEE_AUDIT_JSON: '' }), /::warning title=fee check::the owner invoices could not be read/);
});

test('stale emails: one notice with the counts by audience and code, never an address', () => {
  const j = JSON.stringify({ total: 3, waiting: 12, by_audience: { staff_admin: 2, renter: 1 }, by_code: [{ code: 'staff_review_received', n: 2 }, { code: 'renter_offer_ready', n: 1 }] });
  const out = run('scripts/deploy/outbox-stale.sh', ['--offline'], { OUTBOX_STALE_JSON: j }).trim();
  assert.equal(out, '::notice title=stale emails::3 emails skipped as stale in the last day (never sent late); 12 still waiting.%0ABy audience: staff_admin 2, renter 1%0ABy code:%0A- staff_review_received: 2%0A- renter_offer_ready: 1');
  assert.doesNotMatch(out, /@/);
  assert.match(run('scripts/deploy/outbox-stale.sh', ['--offline'], { OUTBOX_STALE_JSON: '' }), /::warning title=stale emails::/);
});

test('the email binding: 1, true, yes, on or EMAIL (any case) add it, once, and say so; anything else says why not', async () => {
  const { mkdtempSync, writeFileSync, readFileSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const d = mkdtempSync(join(tmpdir(), 'wr-'));
  const base = '{\n  "ai": { "binding": "AI" },\n  "vars": {}\n}\n';
  for (const v of ['EMAIL', 'email', '1', 'true', 'Yes', 'on']) {
    const f = join(d, `w-${v}.jsonc`); writeFileSync(f, base);
    assert.match(run('scripts/deploy/email-binding.sh', [f, 'production', v]), /::notice title=email::EMAIL binding added/, v);
    assert.match(readFileSync(f, 'utf8'), /"send_email": \[\{ "name": "EMAIL" \}\]/, v);
    assert.match(run('scripts/deploy/email-binding.sh', [f, 'production', v]), /already in wrangler\.jsonc/, `${v} twice`);
  }
  for (const v of ['', '0', 'no', 'EMAILS']) {
    const f = join(d, 'w-off.jsonc'); writeFileSync(f, base);
    assert.match(run('scripts/deploy/email-binding.sh', [f, 'production', v]), /::warning title=email::EMAIL binding NOT added: the repository variable CF_EMAIL_BINDING is/, v);
    assert.equal(readFileSync(f, 'utf8'), base, v);
  }
  // 2026-11-06: the file as wrangler-config.mjs rewrites it (plain JSON, "ai" over three lines) gets the binding too
  const rewritten = join(d, 'w-rewritten.json');
  writeFileSync(rewritten, JSON.stringify({ name: 'x', ai: { binding: 'AI' }, env: { staging: { ai: { binding: 'AI' } } } }, null, 2) + '\n');
  assert.match(run('scripts/deploy/email-binding.sh', [rewritten, 'production', 'EMAIL']), /EMAIL binding added/);
  const cfg = JSON.parse(readFileSync(rewritten, 'utf8')) as { send_email?: Array<{ name: string }>; env: { staging: { send_email?: unknown } } };
  assert.deepEqual(cfg.send_email, [{ name: 'EMAIL' }]);
  assert.equal(cfg.env.staging.send_email, undefined);
  const f = join(d, 'w-stg.jsonc'); writeFileSync(f, base);
  assert.match(run('scripts/deploy/email-binding.sh', [f, 'staging', 'EMAIL']), /production only/);
  // the owner-step list treats EMAIL as set
  assert.equal(run('scripts/deploy/owner-steps.sh', ['--offline'], { OWNER_STEPS_JSON: '[]', CF_EMAIL_BINDING: 'EMAIL' }).trim(), '::notice title=owner steps::nothing is waiting on an owner step');
});

test('phone alert keys: made only when the vault has no pair; a P-256 pair in base64url, never the same twice', () => {
  assert.equal(run('scripts/deploy/vapid.sh', ['need', '', '']).trim(), 'yes');
  assert.equal(run('scripts/deploy/vapid.sh', ['need', 'BPub', '']).trim(), 'yes', 'one alone cannot sign');
  assert.equal(run('scripts/deploy/vapid.sh', ['need', 'BPub', 'priv']).trim(), 'no', 'a stored pair is kept, never rotated');
  const [pub, priv] = run('scripts/deploy/vapid.sh', ['make']).trim().split(' ');
  assert.match(pub!, /^[A-Za-z0-9_-]{87}$/);
  assert.equal(Buffer.from(pub!, 'base64url')[0], 4, 'an uncompressed point');
  assert.match(priv!, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(run('scripts/deploy/vapid.sh', ['make']).trim(), `${pub} ${priv}`);
});
