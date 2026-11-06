// Self-heal that learns (release 28, B6): the rules.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SAFE_ACTIONS, decide, learnedActions, type LedgerEntry, type Probe, type Runbook } from './decide.ts';

const raw = JSON.parse(readFileSync(new URL('../../../../.github/self-heal/runbook.json', import.meta.url), 'utf8')) as Record<string, unknown>;
delete raw._about;
const RUNBOOK = raw as Runbook;
const NOW = new Date('2026-11-06T18:00:00Z');
const ago = (h: number) => new Date(NOW.getTime() - h * 3_600_000).toISOString();
const probe = (seen: Record<string, string>, o: Partial<Probe> = {}): Probe => ({ seen, streak: Object.fromEntries(Object.keys(seen).map((k) => [k, 1])), lastVpsOps: null, fixes: [], vps: true, ...o });

test('the runbook names only safe actions; nothing runs SQL', () => {
  for (const [sig, e] of Object.entries(RUNBOOK)) assert.ok(SAFE_ACTIONS.includes(e.action), sig);
  assert.ok(!(SAFE_ACTIONS as readonly string[]).some((a) => /sql|query|psql/i.test(a)));
});

test('the API down: a reboot only after three runs in a row, then not again within 6 hours', () => {
  assert.deepEqual(decide(probe({ api_down: 'HTTP 0' }), RUNBOOK, [], NOW).actions, []);
  const p = decide(probe({ api_down: 'HTTP 0' }, { streak: { api_down: 3 } }), RUNBOOK, [{ at: ago(0.8), signature: 'api_down', event: 'start' }], NOW);
  assert.deepEqual(p.actions.map((a) => a.action), ['reboot']);
  const again = decide(probe({ api_down: 'HTTP 0' }, { streak: { api_down: 6 }, lastVpsOps: ago(2) }), RUNBOOK, [], NOW);
  assert.deepEqual(again.actions, [], 'a vps-ops run 2 hours ago: no second reboot');
  assert.deepEqual(decide(probe({ api_down: 'x' }, { streak: { api_down: 3 }, vps: false }), RUNBOOK, [], NOW).actions, [], 'not the live backend: no reboot');
});

test('a reboot that did not help twice: no third, an issue instead', () => {
  const ledger: LedgerEntry[] = [{ at: ago(14), signature: 'api_down', event: 'start' }, { at: ago(13), signature: 'api_down', event: 'action', action: 'reboot' },
    { at: ago(7), signature: 'api_down', event: 'action', action: 'reboot' }];
  const p = decide(probe({ api_down: 'x' }, { streak: { api_down: 50 } }), RUNBOOK, ledger, NOW);
  assert.deepEqual(p.actions, []);
  assert.match(p.issues[0]!.title, /did not heal/);
});

test('known transient signatures wait without an issue, until they last too long', () => {
  assert.deepEqual(decide(probe({ email_capped: 'capped' }), RUNBOOK, [], NOW).issues, []);
  const long = decide(probe({ email_capped: 'capped' }), RUNBOOK, [{ at: ago(30), signature: 'email_capped', event: 'start' }], NOW);
  assert.equal(long.issues.length, 1);
});

test('an unknown signature opens an issue; a fix line on its closed issue teaches the action', () => {
  const first = decide(probe({ server_health: 'vps-health failing' }), RUNBOOK, [], NOW);
  assert.equal(first.issues.length, 1);
  assert.equal(first.actions.length, 0);
  const taught = decide(probe({ server_health: 'again' }, { fixes: [{ signature: 'server_health', action: 'apply_retention' }] }), RUNBOOK, [], NOW);
  assert.deepEqual(taught.actions.map((a) => a.action), ['apply_retention']);
  assert.ok(taught.ledger.some((e) => e.event === 'learned' && e.action === 'apply_retention'));
  // learned once, it stays learned from the ledger alone
  assert.equal(learnedActions(taught.ledger, [])['server_health'], 'apply_retention');
  // an unsafe action named in a fix line is ignored
  assert.equal(learnedActions([], [{ signature: 'x', action: 'drop_table' }])['x'], undefined);
});

test('a failed scheduled workflow is re-run, once per cooldown; the kind comes from the signature', () => {
  const p = decide(probe({ 'cron_failed:gsc': 'run 1 failed' }), RUNBOOK, [], NOW);
  assert.deepEqual(p.actions.map((a) => a.action), ['rerun_failed']);
  const soon = decide(probe({ 'cron_failed:gsc': 'run 1 failed' }), RUNBOOK, [{ at: ago(1), signature: 'cron_failed:gsc', event: 'action', action: 'rerun_failed' }], NOW);
  assert.deepEqual(soon.actions, []);
});

test('the ledger: a start when first seen, an end when gone', () => {
  const p = decide(probe({ site_slow: '9000 ms' }), RUNBOOK, [{ at: ago(1), signature: 'cron_failed:gsc', event: 'start' }], NOW);
  assert.ok(p.ledger.some((e) => e.signature === 'site_slow' && e.event === 'start'));
  assert.deepEqual(p.ended, ['cron_failed:gsc']);
  assert.ok(p.ledger.some((e) => e.signature === 'cron_failed:gsc' && e.event === 'end' && e.outcome === 'recovered'));
});
