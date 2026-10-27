import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claimView, opensToYou, type ClaimState } from './claim.ts';

const now = Date.parse('2026-10-27T14:00:00Z');
const base: ClaimState = { booking: 'b', status: 'requested', current_offer_version: null, claim: null, sales_opens_at: null, sales_waits: false, sales_text: null, admin: false, minutes: 20 };
const claim = (mine: boolean, minutes = 10) => ({ by: 'u', name: 'Val Cs', since: '2026-10-27T13:55:00Z', until: new Date(now + minutes * 60_000).toISOString(), mine, text: 'Being answered by Val Cs since 9:55 am' });

test('claimView (0177): nobody on it, nothing locked and no line', () => {
  assert.deepEqual(claimView(base, now), { locked: false, note: null, canTakeOver: false, mine: false });
});

test('claimView: someone else on it, locked with who and since when; an Admin may take over', () => {
  const v = claimView({ ...base, claim: claim(false) }, now);
  assert.equal(v.locked, true);
  assert.match(v.note ?? '', /^Being answered by Val Cs since 9:55 am\. The offer and decline buttons are off until .+ at 10:10 am\.$/);
  assert.equal(v.canTakeOver, false);
  assert.equal(claimView({ ...base, admin: true, claim: claim(false) }, now).canTakeOver, true);
});

test('claimView: mine is not locked', () => {
  const v = claimView({ ...base, claim: claim(true) }, now);
  assert.deepEqual([v.locked, v.mine], [false, true]);
  assert.ok(v.note?.includes('You are answering this request'));
});

test('claimView: a claim that ran out locks nothing', () => {
  assert.equal(claimView({ ...base, claim: claim(false, -1) }, now).locked, false);
});

test('claimView: Sales during the wait are locked; it opens to them later', () => {
  const v = claimView({ ...base, sales_waits: true, sales_opens_at: '2026-10-27T14:15:00Z', sales_text: 'Open to Sales at 10:15 am if nobody answers' }, now);
  assert.deepEqual(v, { locked: true, note: 'Open to Sales at 10:15 am if nobody answers. Customer service answers it first.', canTakeOver: false, mine: false });
  assert.equal(opensToYou('2026-10-27T14:15:00Z'), 'Opens to you at 10:15 am');
  assert.equal(opensToYou(null), null);
});

test('claimView: others during the wait see when it opens to Sales', () => {
  assert.equal(claimView({ ...base, sales_text: 'Open to Sales at 10:15 am if nobody answers' }, now).note, 'Open to Sales at 10:15 am if nobody answers.');
});

test('claimView: not a request, nothing', () => {
  assert.equal(claimView({ ...base, status: 'offered', claim: claim(false) }, now).locked, false);
  assert.equal(claimView(null, now).note, null);
});
