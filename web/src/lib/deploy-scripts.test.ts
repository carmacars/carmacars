// The deploy and backup shell rules (0320, 0321): which logical backups are kept (scripts/backup/keep.sh) and the owner-step
// annotation of every deploy (scripts/deploy/owner-steps.sh, offline: no database).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '../../..');
const run = (script: string, args: string[], env: Record<string, string> = {}) =>
  execFileSync('bash', [join(ROOT, script), ...args], { encoding: 'utf8', env: { ...process.env, CF_EMAIL_BINDING: '', OWNER_STEPS_JSON: '', GITHUB_STEP_SUMMARY: '', ...env } });

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
