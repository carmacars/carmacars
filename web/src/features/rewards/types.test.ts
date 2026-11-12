import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ladderView, pointsWorth, redeemSteps, tierRank, type Ladder } from './types.ts';

test('redeem choices start at the minimum and end at the balance', () => {
  assert.deepEqual(redeemSteps(400, 500), []);
  const s = redeemSteps(1340, 500);
  assert.equal(s[0], 500);
  assert.equal(s[s.length - 1], 1300);
  assert.ok(s.every((p) => p <= 1340 && p % 100 === 0));
});
test('100 points are a dollar by default', () => {
  assert.equal(pointsWorth(1000, 1), 1000);
  assert.equal(pointsWorth(250, 0.5), 125);
});

// r40 (2421): three tiers by points earned in 12 months; below Gold a Member; perks add up
const L = (pts: number, code: string | null): Ladder => ({ points_12m: pts, tier_code: code, any_car_hours: 4, free_day: null, tiers: [
  { code: 'platinum', name: 'Platinum', min_points: 15000, perks: [{ code: 'any_car', label: 'Any car, any time', detail: null }] },
  { code: 'gold', name: 'Gold', min_points: 1000, perks: [{ code: 'instant_book', label: 'Instant Book', detail: null }] },
  { code: 'black', name: 'Black', min_points: 60000, perks: [{ code: 'free_day', label: 'A free rental day every year', detail: null }] }] });

test('a Member below Gold: points to Gold, no perks, the bar inside the first step', () => {
  const v = ladderView(L(240, null));
  assert.equal(v.current, null);
  assert.equal(v.next?.code, 'gold');
  assert.equal(v.line, '760 more points to Gold');
  assert.deepEqual(v.perks, []);
  assert.ok(v.progress > 0 && v.progress < 1 / 3);
  assert.deepEqual(v.states.map((s) => s.state), ['now', 'later', 'later']);
});
test('Platinum keeps the Gold perk; the line names Black with the points in thousands', () => {
  const v = ladderView(L(13760 + 1240 + 1000, 'platinum'));
  assert.equal(v.current?.code, 'platinum');
  assert.equal(v.line, '44,000 more points to Black');
  assert.deepEqual(v.perks.map((p) => p.code), ['instant_book', 'any_car']);
  assert.deepEqual(v.states.map((s) => s.state), ['done', 'done', 'now']);
});
test('at the top: every perk, a full bar; ranks for the celebration', () => {
  const v = ladderView(L(61000, 'black'));
  assert.equal(v.line, 'You are at the top: Black');
  assert.equal(v.progress, 1);
  assert.equal(v.perks.length, 3);
  assert.equal(tierRank(L(0, null)), 0);
  assert.equal(tierRank(L(0, 'black')), 3);
  assert.equal(tierRank(L(0, null), 'gold'), 1);
});
