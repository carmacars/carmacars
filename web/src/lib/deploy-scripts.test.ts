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
