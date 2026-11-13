import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NO_CHOICE, afterReturnText, centsOf, choiceAmount, choiceNeedsAdmin, choicePayload, choiceProblem, chosenDays, decisionText, optionDetail, type LateChoice, type LateReturn } from './late-return.ts';

// a car back 26 hours late on a booking that costs $90.00 a day, with a $25.00 hourly late fee
const late = (may: Partial<LateReturn['may']> = {}): LateReturn => ({
  booking_id: 'b', booking_number: 'CC-1', back: true, minutes_late: 1560, grace_minutes: 30, late: true, late_text: '1 d 2 h',
  daily_cents: 9000, hourly_cents: 2500, hst_bps: 1300, decision: null, locked: false,
  options: [
    { key: 'extension', days: 2, amount_cents: 18000 },
    { key: 'extra_days', days: 1, max_days: 2, unit_cents: 9000, amount_cents: 9000 },
    { key: 'late_fee', amount_cents: 14000, extra_days: 1, extra_days_cents: 9000, late_fee_cents: 5000, set: true },
    { key: 'custom' }, { key: 'waive' }],
  may: { decide: true, admin: false, waive: false, limit_cents: 10000, ...may }
});
const pick = (c: Partial<LateChoice>): LateChoice => ({ ...NO_CHOICE, ...c });

test('nothing chosen is "decide later": no problem, nothing sent', () => {
  assert.equal(choiceProblem(NO_CHOICE, late()), null);
  assert.equal(choicePayload(NO_CHOICE, late()), null);
  assert.equal(choiceAmount(NO_CHOICE, late()), null);
});

test('an extension is every started day at the daily rate', () => {
  assert.equal(choiceAmount(pick({ option: 'extension' }), late()), 18000);
  assert.deepEqual(choicePayload(pick({ option: 'extension' }), late()), { option: 'extension' });
  assert.match(optionDetail('extension', late()), /2 days at the daily rate of \$90\.00: \$180\.00 plus tax/);
});

test('extra days: the whole days late by default, 1 up to the started days', () => {
  assert.equal(chosenDays(pick({ option: 'extra_days' }), late()), 1);
  assert.equal(choiceAmount(pick({ option: 'extra_days', days: '2' }), late()), 18000);
  assert.deepEqual(choicePayload(pick({ option: 'extra_days', days: '2' }), late()), { option: 'extra_days', days: 2 });
  assert.equal(choiceProblem(pick({ option: 'extra_days', days: '3' }), late()), 'Choose 1 to 2 extra days.');
  assert.equal(choiceProblem(pick({ option: 'extra_days', days: '0' }), late()), 'Choose 1 to 2 extra days.');
  assert.equal(choicePayload(pick({ option: 'extra_days', days: '3' }), late()), null);
});

test('the late return fee is what the rental terms say, and cannot be chosen while it is not set', () => {
  assert.equal(choiceAmount(pick({ option: 'late_fee' }), late()), 14000);
  assert.match(optionDetail('late_fee', late()), /\$140\.00 plus tax, by the rental terms: 1 day at the daily rate and \$50\.00 for the hours after/);
  const unset = late(); unset.options[2] = { key: 'late_fee', amount_cents: 0, set: false };
  assert.match(choiceProblem(pick({ option: 'late_fee' }), unset) ?? '', /not set in the fee defaults/);
});

test('a custom amount needs the amount and what it is for; above the limit it waits for an Admin', () => {
  assert.equal(choiceProblem(pick({ option: 'custom' }), late()), 'Enter the amount to charge.');
  assert.equal(choiceProblem(pick({ option: 'custom', amount: '40' }), late()), 'Say what the amount is for: the renter sees it.');
  const ok = pick({ option: 'custom', amount: '40.50', reason: 'Half a day agreed by phone' });
  assert.equal(choiceProblem(ok, late()), null);
  assert.deepEqual(choicePayload(ok, late()), { option: 'custom', amount_cents: 4050, reason: 'Half a day agreed by phone' });
  assert.equal(choiceNeedsAdmin(ok, late()), false);
  assert.equal(choiceNeedsAdmin(pick({ option: 'custom', amount: '100.01', reason: 'Two days agreed' }), late()), true);
  assert.equal(choiceNeedsAdmin(pick({ option: 'custom', amount: '5000', reason: 'Two days agreed' }), late({ admin: true, limit_cents: null })), false);
});

test('a waiver needs its reason; it waits for an Admin unless the person may waive', () => {
  assert.equal(choiceProblem(pick({ option: 'waive' }), late()), 'Say why the late return is waived.');
  const w = pick({ option: 'waive', reason: 'Road closed, called ahead' });
  assert.equal(choiceAmount(w, late()), 0);
  assert.equal(choiceNeedsAdmin(w, late()), true);
  assert.equal(choiceNeedsAdmin(w, late({ waive: true })), false);
  assert.match(optionDetail('waive', late()), /waits for an Admin/);
});

test('amounts typed by staff', () => {
  assert.equal(centsOf('12.5'), 1250);
  assert.equal(centsOf('$1,250'), 125000);
  assert.equal(centsOf('12.555'), null);
  assert.equal(centsOf(''), null);
});

test('the decision in words', () => {
  const base = { days: null, amount_cents: null, reason: null, requested_by: null, requested_at: null, decided_by: 'Sam', decided_at: '2026-11-12T15:00:00Z', charged_cents: 10170 };
  assert.match(decisionText({ ...base, status: 'pending', option: null }), /Nothing is charged until someone chooses/);
  assert.equal(decisionText({ ...base, status: 'decided', option: 'extra_days', days: 1 }), 'The late return was charged 1 day at the daily rate: $101.70 with tax, by Sam.');
  assert.equal(decisionText({ ...base, status: 'decided', option: 'waive', reason: 'Road closed', charged_cents: 0 }), 'The late return was waived (Road closed), by Sam.');
  assert.match(decisionText({ ...base, status: 'needs_admin', option: 'custom', amount_cents: 50000, reason: 'Missed the next rental', requested_by: 'Lee', decided_by: null }), /^Waiting for an Admin: Lee asked .* \$500\.00\.$/);
});

test('after the return: what the screen says about the late return', () => {
  assert.equal(afterReturnText(null), '');
  assert.match(afterReturnText({ status: 'decided' }), /charged as you chose/);
  assert.match(afterReturnText({ status: 'needs_admin' }), /waits for an Admin/);
  assert.match(afterReturnText({ status: 'pending' }), /not chosen yet/);
});
