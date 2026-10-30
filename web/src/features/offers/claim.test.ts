import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claimFree, claimView, opensToYou, type ClaimState } from './claim.ts';

const now = Date.parse('2026-10-27T14:00:00Z');
const base: ClaimState = { booking: 'b', status: 'requested', current_offer_version: null, claim: null, sales_opens_at: null, sales_waits: false, sales_text: null, admin: false, minutes: 20 };
const claim = (mine: boolean, minutes = 10) => ({ by: 'u', name: 'Val Cs', since: '2026-10-27T13:55:00Z', until: new Date(now + minutes * 60_000).toISOString(), mine, text: 'Being answered by Val Cs since 9:55 am' });

test('claimView (0177): nobody on it, nothing locked and no line', () => {
  assert.deepEqual(claimView(base, now), { locked: false, note: null, canTakeOver: false, mine: false, why: null, opensAt: null });
  assert.equal(claimFree(base, now), true);
});

test('claimView: someone else on it, locked with who and since when; an Admin may take over', () => {
  const v = claimView({ ...base, claim: claim(false) }, now);
  assert.equal(v.locked, true);
  assert.match(v.note ?? '', /^Being answered by Val Cs since 9:55 am\. The offer and decline buttons are off until .+ at 10:10 am\.$/);
  assert.equal(v.canTakeOver, false);
  assert.equal(claimView({ ...base, admin: true, claim: claim(false) }, now).canTakeOver, true);
  // 2026-10-28: beside the buttons, why they are off and when they come on; the way forward
  assert.match(v.why ?? '', /^Val Cs is answering this request\. Their claim runs out at 10:10 am unless they keep working on it; the buttons come on by themselves then.+ask an Admin to take it over\.$/);
  assert.equal(v.opensAt, claim(false).until);
  assert.match(claimView({ ...base, admin: true, claim: claim(false) }, now).why ?? '', /Press Take over to answer it yourself now\.$/);
  assert.equal(claimFree({ ...base, claim: claim(false) }, now), false);
});

test('claimView: mine is not locked', () => {
  const v = claimView({ ...base, claim: claim(true) }, now);
  assert.deepEqual([v.locked, v.mine, v.why], [false, true, null]);
  assert.ok(v.note?.includes('You are answering this request'));
});

test('claimView: a claim that ran out locks nothing', () => {
  assert.equal(claimView({ ...base, claim: claim(false, -1) }, now).locked, false);
  assert.equal(claimFree({ ...base, claim: claim(false, -1) }, now), true);
});

test('claimView: Sales during the wait are locked; it opens to them later', () => {
  const v = claimView({ ...base, sales_waits: true, sales_opens_at: '2026-10-27T14:15:00Z', sales_text: 'Open to Sales at 10:15 am if nobody answers' }, now);
  assert.deepEqual([v.locked, v.note, v.canTakeOver, v.mine, v.opensAt], [true, 'Open to Sales at 10:15 am if nobody answers. Customer service answers it first.', false, false, '2026-10-27T14:15:00Z']);
  assert.match(v.why ?? '', /^A request from the website goes to customer service first\. It opens to you at 10:15 am if nobody has answered it: the buttons come on by themselves then\./);
  assert.equal(claimFree({ ...base, sales_waits: true }, now), false);
  assert.equal(opensToYou('2026-10-27T14:15:00Z'), 'Opens to you at 10:15 am');
  assert.equal(opensToYou(null), null);
});

test('claimView: others during the wait see when it opens to Sales', () => {
  assert.equal(claimView({ ...base, sales_text: 'Open to Sales at 10:15 am if nobody answers' }, now).note, 'Open to Sales at 10:15 am if nobody answers.');
});

test('claimView: not a request, nothing', () => {
  assert.equal(claimView({ ...base, status: 'offered', claim: claim(false) }, now).locked, false);
  assert.equal(claimView(null, now).note, null);
  assert.equal(claimFree({ ...base, status: 'offered' }, now), false);
  assert.equal(claimFree(null, now), false);
});
