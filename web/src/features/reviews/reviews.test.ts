// The review request program (0146): the draft is made only from what the renter gave and the booking's facts; the
// sequence's timing inside the sending hours; the hold's summary; Google reviews matched to renters by name.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { draftReview, hasInput, LIKED, tidySentence, unhappy, type DraftAnswers, type DraftFacts, type Liked } from './draft.ts';
import { holdLine, holdSummary, inWindow, nextWindow, planSequence, torontoAt, DEFAULT_SETTINGS } from './sequence.ts';
import { matchReviews, nameScore } from './match.ts';

const facts = (o: Partial<DraftFacts> = {}): DraftFacts => ({ vehicle: '2023 Mercedes-Benz C 300', days: 3, delivered: false, staff: ['Sam'], ...o });
const answers = (o: Partial<DraftAnswers> = {}): DraftAnswers => ({ liked: [], staff: [], stars: null, sentence: '', ...o });

// ---------------------------------------------------------------- the draft
test('draft: nothing without the renter’s input (the booking’s facts alone write no review)', () => {
  assert.equal(draftReview(facts(), answers()), '');
  assert.equal(draftReview(facts(), answers({ stars: 5 })), '');
  assert.equal(draftReview(facts(), answers({ sentence: '   ' })), '');
  assert.equal(hasInput(answers({ staff: ['Someone else'] }), facts()), false, 'a staff name not on the booking is no input');
});

test('draft: states the booking’s facts (car, length, delivery) and nothing they did not pick', () => {
  const d = draftReview(facts({ delivered: true, days: 4 }), answers({ liked: ['car'] }));
  assert.match(d, /2023 Mercedes-Benz C 300/);
  assert.match(d, /4 days/);
  assert.match(d, /deliver/i);
  // praise words of the chips not picked never appear
  assert.doesNotMatch(d, /clean|price|value|communicat|book(ing)? was|easy to book|simple|smooth|went well/i);
  assert.equal(draftReview(facts({ days: 1 }), answers({ liked: ['price'] })).includes('for a day'), true);
  assert.doesNotMatch(draftReview(facts({ vehicle: null, days: null }), answers({ liked: ['price'] })), /null|undefined|NaN/);
});

const WORDS: Record<Liked, RegExp> = {
  car: /the car (was great|itself)|liked the car/i,
  handover: /pickup|delivery/i,
  communication: /communicat/i,
  price: /price|value/i,
  cleanliness: /clean/i,
  easy_booking: /book/i
};

test('draft: one phrase per chip picked, never one for a chip not picked, for every seed', () => {
  for (let seed = 0; seed < 40; seed++) {
    for (const k of LIKED) {
      const d = draftReview(facts(), answers({ liked: [k] }), seed);
      // the opener names CarmaCars and the car; strip it before looking for phrases
      const body = d.replace(/^[^.]*\.\s*/, '');
      for (const other of LIKED) {
        if (other === k) assert.match(body, WORDS[other], `${k} (seed ${seed}): ${d}`);
        else assert.doesNotMatch(body, WORDS[other], `${k} must not say ${other} (seed ${seed}): ${d}`);
      }
    }
  }
});

test('draft: pickup or delivery follows the booking (never "delivery" for a pickup)', () => {
  for (let seed = 0; seed < 20; seed++) {
    assert.doesNotMatch(draftReview(facts({ delivered: false }), answers({ liked: ['handover'] }), seed), /deliver/i);
    assert.match(draftReview(facts({ delivered: true }), answers({ liked: ['handover'] }), seed), /deliver/i);
  }
});

test('draft: staff only by the names on the booking the renter tapped', () => {
  const d = draftReview(facts({ staff: ['Sam', 'Ali'] }), answers({ staff: ['Sam', 'Bob'] }), 3);
  assert.match(d, /Sam/);
  assert.doesNotMatch(d, /Bob|Ali/);
  assert.match(draftReview(facts({ staff: ['Sam', 'Ali'] }), answers({ staff: ['Sam', 'Ali'] }), 1), /Sam and Ali/);
});

test('draft: their sentence as written, tidied; long dashes become commas', () => {
  const d = draftReview(facts(), answers({ sentence: '  the  heated seats were perfect for the drive to Ottawa  ' }), 2);
  assert.match(d, /The heated seats were perfect for the drive to Ottawa\.$/);
  assert.equal(tidySentence('Great trip \u2014 thanks'), 'Great trip, thanks.');
  assert.equal(tidySentence('Loved it!'), 'Loved it!');
  assert.doesNotMatch(draftReview(facts(), answers({ liked: [...LIKED], staff: ['Sam'], sentence: 'Fine' }), 9), /[\u2013\u2014]/);
});

test('draft: the stars are not written into the text, and a low star feel offers "tell us directly"', () => {
  const a = draftReview(facts(), answers({ liked: ['car'], stars: 2 }), 1);
  const b = draftReview(facts(), answers({ liked: ['car'], stars: 5 }), 1);
  assert.equal(a, b);
  assert.doesNotMatch(a, /star|out of 5/i);
  assert.equal(unhappy(2), true); assert.equal(unhappy(3), true); assert.equal(unhappy(4), false); assert.equal(unhappy(null), false);
});

test('draft: the phrasing varies with the seed, the same seed gives the same draft', () => {
  const a = answers({ liked: ['car', 'cleanliness', 'easy_booking'] });
  assert.equal(draftReview(facts(), a, 7), draftReview(facts(), a, 7));
  const seen = new Set(Array.from({ length: 12 }, (_, i) => draftReview(facts(), a, i)));
  assert.ok(seen.size >= 3, `only ${seen.size} variants`);
  // short: a few sentences
  assert.ok(draftReview(facts(), answers({ liked: [...LIKED], staff: ['Sam'], sentence: 'Would recommend to friends.' }), 4).length < 400);
});

// ---------------------------------------------------------------- the timing
test('timing: the sending hours (9 am to 9 pm Toronto) and the next opening', () => {
  assert.equal(inWindow(torontoAt(2026, 11, 5, 9), 9, 21), true);
  assert.equal(inWindow(new Date(torontoAt(2026, 11, 5, 9).getTime() - 60_000), 9, 21), false);
  assert.equal(inWindow(torontoAt(2026, 11, 5, 21), 9, 21), false);
  assert.equal(nextWindow(torontoAt(2026, 11, 5, 6), 9, 21).toISOString(), torontoAt(2026, 11, 5, 9).toISOString());
  assert.equal(nextWindow(torontoAt(2026, 11, 5, 22), 9, 21).toISOString(), torontoAt(2026, 11, 6, 9).toISOString());
  const noon = torontoAt(2026, 11, 5, 12);
  assert.equal(nextWindow(noon, 9, 21).toISOString(), noon.toISOString());
  // across the end of daylight time (November 1, 2026) and a month end
  assert.equal(nextWindow(torontoAt(2026, 10, 31, 23), 9, 21).toISOString(), '2026-11-01T14:00:00.000Z');
  assert.equal(torontoAt(2026, 7, 1, 9).toISOString(), '2026-07-01T13:00:00.000Z');
});

test('timing: check-in 24 h after pickup (2 days or more), request 1 h after check-in, reminder 24 h, final 7 days', () => {
  const plan = planSequence({ pickupAt: torontoAt(2026, 11, 2, 10), returnAt: torontoAt(2026, 11, 5, 10), returnedAt: torontoAt(2026, 11, 5, 10), sent: {} });
  const at = Object.fromEntries(plan.map((p) => [p.step, p.sendAt?.toISOString() ?? p.skipped]));
  assert.deepEqual(at, {
    checkin: torontoAt(2026, 11, 3, 10).toISOString(), ask: torontoAt(2026, 11, 5, 11).toISOString(),
    reminder: torontoAt(2026, 11, 6, 11).toISOString(), final: torontoAt(2026, 11, 12, 11).toISOString()
  });
});

test('timing: a step due at night goes at 9 am; the follow-ups count from when the request went', () => {
  const plan = planSequence({ pickupAt: torontoAt(2026, 11, 2, 22), returnAt: torontoAt(2026, 11, 5, 20), returnedAt: torontoAt(2026, 11, 5, 20) /* request due 9 pm */, sent: {} });
  const by = Object.fromEntries(plan.map((p) => [p.step, p]));
  assert.equal(by.checkin!.sendAt!.toISOString(), torontoAt(2026, 11, 4, 9).toISOString());
  assert.equal(by.ask!.sendAt!.toISOString(), torontoAt(2026, 11, 6, 9).toISOString());
  assert.equal(by.reminder!.sendAt!.toISOString(), torontoAt(2026, 11, 7, 9).toISOString());
  const sent = planSequence({ pickupAt: torontoAt(2026, 11, 2, 10), returnAt: torontoAt(2026, 11, 5, 10), returnedAt: torontoAt(2026, 11, 5, 10), sent: { ask: torontoAt(2026, 11, 9, 14) } });
  assert.equal(sent.find((p) => p.step === 'ask')!.sentAt!.toISOString(), torontoAt(2026, 11, 9, 14).toISOString());
  assert.equal(sent.find((p) => p.step === 'reminder')!.sendAt!.toISOString(), torontoAt(2026, 11, 10, 14).toISOString());
});

test('timing: no check-in for a short rental, when it is off, or too close to the return', () => {
  const one = planSequence({ pickupAt: torontoAt(2026, 11, 2, 10), returnAt: torontoAt(2026, 11, 3, 10), returnedAt: null, sent: {} });
  assert.equal(one[0]!.sendAt, null); assert.match(one[0]!.skipped!, /under 2 days/);
  const off = planSequence({ pickupAt: torontoAt(2026, 11, 2, 10), returnAt: torontoAt(2026, 11, 6, 10), returnedAt: null, sent: {} }, { ...DEFAULT_SETTINGS, checkinEnabled: false });
  assert.equal(off[0]!.skipped, 'off in settings');
  const late = planSequence({ pickupAt: torontoAt(2026, 11, 2, 10), returnAt: torontoAt(2026, 11, 4, 12), returnedAt: null, sent: {} }, { ...DEFAULT_SETTINGS, checkinAfterHours: 48 });
  assert.equal(late[0]!.skipped, 'too close to the return');
});

// ---------------------------------------------------------------- the hold
test('hold: open items grouped by reason, return charges first, with their totals', () => {
  const items = [
    { reason: 'tolls', amount_cents: 1200, label: 'Toll' }, { reason: 'late', amount_cents: 5000 }, { reason: 'tolls', amount_cents: 300 },
    { reason: 'incident', amount_cents: null }, { reason: 'weird', amount_cents: 100 }
  ];
  assert.deepEqual(holdSummary(items).map((g) => `${g.reason}:${g.count}:${g.amount_cents}`), ['late:1:5000', 'tolls:2:1500', 'other:1:100', 'incident:1:0']);
  assert.equal(holdLine(items), 'Late return $50.00, Tolls and tickets $15.00, Other charges $1.00, Open incident');
  assert.deepEqual(holdSummary([]), [], 'nothing open: not on hold');
});

// ---------------------------------------------------------------- Google matches
test('names: full, first and last, initial, small typo, first name only, other people', () => {
  assert.equal(nameScore('Maya Okafor', 'Maya Okafor'), 1);
  assert.equal(nameScore('maya okafor', 'Maya  Okafor'), 1);
  assert.equal(nameScore('Maya O.', 'Maya Okafor'), 0.85);
  assert.equal(nameScore('Maya Okafor', 'Maya Adaeze Okafor'), 0.95);
  assert.equal(nameScore('José García', 'Jose Garcia'), 1);
  assert.equal(nameScore('Mayah Okafor', 'Maya Okafor') >= 0.85, false, 'a short first name with a typo is not close enough');
  assert.equal(nameScore('Maya Okafur', 'Maya Okafor'), 0.85);
  assert.equal(nameScore('Maya', 'Maya Okafor'), 0.6);
  assert.equal(nameScore('Daniel Rossi', 'Maya Okafor'), 0);
  assert.equal(nameScore(null, 'Maya Okafor'), 0);
});

test('matches: a clear name in the window is matched; first name only is suggested; outside the window or two people is not matched', () => {
  const cands = [
    { booking_id: 'b1', renter_name: 'Maya Okafor', returned_at: '2026-11-05T15:00:00Z' },
    { booking_id: 'b2', renter_name: 'Maya Chen', returned_at: '2026-11-06T15:00:00Z' },
    { booking_id: 'b3', renter_name: 'Daniel Rossi', returned_at: '2026-09-01T15:00:00Z' },
    { booking_id: 'b4', renter_name: 'Maya Okafor', returned_at: '2026-10-20T15:00:00Z' }
  ];
  const out = matchReviews([
    { id: 'r1', reviewer_name: 'Maya Okafor', reviewed_at: '2026-11-07T12:00:00Z' },
    { id: 'r2', reviewer_name: 'Maya', reviewed_at: '2026-11-07T12:00:00Z' },
    { id: 'r3', reviewer_name: 'Daniel Rossi', reviewed_at: '2026-11-07T12:00:00Z' },
    { id: 'r4', reviewer_name: 'Maya Okafor', reviewed_at: '2026-11-04T12:00:00Z' },
    { id: 'r5', reviewer_name: 'Someone', reviewed_at: '2026-11-07T12:00:00Z' }
  ], cands, { windowDays: 30, autoMatch: true });
  const by = Object.fromEntries(out.map((m) => [m.id, `${m.status}:${m.booking_id ?? '-'}`]));
  assert.deepEqual(by, {
    r1: 'matched:b1', // the latest return of the same renter
    r2: 'suggested:b2', // two Mayas: staff decide
    r3: 'unmatched:-', // returned more than 30 days before
    r4: 'matched:b4', // a review before the return of b1 belongs to the earlier trip
    r5: 'unmatched:-'
  });
  assert.equal(matchReviews([{ id: 'r1', reviewer_name: 'Maya Okafor', reviewed_at: '2026-11-07T12:00:00Z' }], cands, { windowDays: 30, autoMatch: false })[0]!.status, 'suggested');
});
