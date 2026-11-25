import { test } from 'node:test';
import assert from 'node:assert/strict';
import { attemptWords, healedWords, saveOptions, splitIncidents, successRate, type HealAction, type HealIncident, type HealPlaybook } from './model.ts';

const inc = (status: HealIncident['status'], healed_by: HealIncident['healed_by'] = null) => ({ id: status, status, healed_by }) as unknown as HealIncident;

test('self-healing: the words of an attempt follow its result and the check after it', () => {
  assert.equal(attemptWords({ at: '', action: 'restart_web', playbook: 'Restart', result: 'ok', verified: true, details: {} }), 'Restart: the problem was gone after it');
  assert.equal(attemptWords({ at: '', action: 'restart_web', playbook: null, result: 'ok', verified: false, details: { check: 'Still there after the fix' } }), 'restart_web: the problem was still there');
  assert.equal(attemptWords({ at: '', action: 'x', playbook: 'X', result: 'error', verified: false, details: { error: 'boom' } }), 'X: could not run (boom)');
  assert.equal(attemptWords({ at: '', action: 'x', playbook: 'X', result: 'queued', verified: null, details: {} }), 'X: waiting for the server');
  assert.equal(attemptWords({ at: '', action: 'x', playbook: 'X', result: 'ok', verified: null, details: {} }), 'X: done, checking');
});

test('self-healing: healed, escalated and open incidents are told apart', () => {
  assert.equal(healedWords(inc('healed', 'playbook')), 'Fixed by itself');
  assert.equal(healedWords(inc('healed', 'staff')), 'Resolved by an Admin');
  assert.equal(healedWords(inc('healed', 'itself')), 'Cleared on its own');
  assert.equal(healedWords(inc('escalated')), 'Needs you');
  const s = splitIncidents([inc('escalated'), inc('open'), inc('healing'), inc('healed', 'playbook')]);
  assert.deepEqual([s.escalated.length, s.working.length, s.healed.length], [1, 2, 1]);
});

test('self-healing: the success rate, and the fixes offered for an incident (its source\'s own first)', () => {
  assert.equal(successRate({ successes: 0, failures: 0 }), null);
  assert.equal(successRate({ successes: 3, failures: 1 }), 75);
  const actions: HealAction[] = [{ key: 'restart_web', label: 'Restart the website', kind: 'server', description: '' }, { key: 'requeue_outbox', label: 'Send stuck messages again', kind: 'db', description: '' }];
  const books = [{ source: 'queue', action: 'requeue_outbox' }] as HealPlaybook[];
  assert.deepEqual(saveOptions(actions, books, 'queue'), [['requeue_outbox', 'Send stuck messages again'], ['restart_web', 'Restart the website (server)']]);
});
