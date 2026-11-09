// The staff onboarding gate (1151).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupsLeft, markable, rowWords, STEP_LABEL, type OnboardingRow } from './model.ts';

const row = (p: Partial<OnboardingRow> & { state: OnboardingRow['state'] }): OnboardingRow => ({ user_id: 'u', name: 'Sam Example', functions: ['sales'], onboarded: false, groups: [], marked_by: null, ...p });

test('the steps, in order, in words', () => {
  assert.deepEqual(Object.values(STEP_LABEL), ['Academy', 'Staff agreement', 'WhatsApp groups', 'Onboarded']);
  assert.match(rowWords(row({ state: { member: true, step: 'academy', done: false } })), /step 1: the academy/);
  assert.match(rowWords(row({ state: { member: true, step: 'agreement', done: false } })), /step 2: the staff agreement/);
  assert.equal(rowWords(row({ state: { member: true, step: 'whatsapp', done: false }, groups: [{ key: 'sales', name: 'CARMA Closers', url: '', joined: true }, { key: 'team', name: 'CarmaCars Team', url: '', joined: false }] })),
    'Held at step 3: CARMA Closers joined, CarmaCars Team not confirmed.');
  assert.match(rowWords(row({ onboarded: true, marked_by: 'Ada Admin', state: { member: true, step: 'done', done: true } })), /marked by Ada Admin/);
  assert.match(rowWords(row({ state: { member: true, step: 'academy', done: false, exempt: true } })), /^Exempt/);
});

test('the groups left to tick, and who the bulk Mark joined marks (signed, not confirmed, not exempt)', () => {
  assert.deepEqual(groupsLeft([{ key: 'sales', name: 'S', url: '', joined: true }, { key: 'team', name: 'T', url: '' }]).map((g) => g.key), ['team']);
  const rows = [row({ user_id: 'a', state: { member: true, step: 'whatsapp', agreement: true, whatsapp: false, done: false } }),
    row({ user_id: 'b', state: { member: true, step: 'agreement', agreement: false, whatsapp: false, done: false } }),
    row({ user_id: 'c', onboarded: true, state: { member: true, step: 'done', agreement: true, whatsapp: true, done: true } }),
    row({ user_id: 'd', state: { member: true, step: 'whatsapp', agreement: true, whatsapp: false, done: false, exempt: true } })];
  assert.deepEqual(markable(rows).map((r) => r.user_id), ['a']);
});
