import { test } from 'node:test';
import assert from 'node:assert/strict';
import { walkView, type DbStep, type Facts, type Walk } from './model.ts';

const facts = (p: Partial<Facts> = {}): Facts => ({ number: 'CC-10001', status: 'confirmed', pickupWhen: 'Sat, Apr 11, 10 AM', returnWhen: 'Tue, Apr 14, 10 AM', pickupPlace: '1 Example St',
  returnPlace: null, delivery: false, depositText: '$500', cardLast4: '4242', kmTotal: 600, overageText: '$0.35', prepaidFuel: false, phone: '416-555-0100', roadside: null,
  mapsPickup: 'https://www.google.com/maps/search/?api=1&query=1%20Example%20St', mapsReturn: null, handedOver: false, checkedIn: false, ...p });
const KEYS: Array<[DbStep['key'], DbStep['stage'], DbStep['kind']]> = [['licence', 'before', 'task'], ['sign', 'before', 'task'], ['pay', 'before', 'task'], ['deposit', 'before', 'task'],
  ['bring', 'before', 'read'], ['meet', 'pickup', 'read'], ['inspect', 'pickup', 'task'], ['own_photos', 'pickup', 'read'], ['rules', 'road', 'read'], ['help', 'road', 'read'],
  ['return_prep', 'return', 'read'], ['checkin', 'return', 'task'], ['deposit_back', 'return', 'task']];
const walk = (stage: DbStep['stage'], done: string[], extra: Partial<Record<string, Partial<DbStep>>> = {}): Walk => ({ enabled: true, booking_id: 'b', stage,
  steps: KEYS.map(([key, st, kind]) => ({ key, stage: st, kind, done: done.includes(key), needed: key === 'deposit' ? true : undefined, ...(extra[key] ?? {}) })) });

test('before pickup: the first step not done is the one to do now, with its page', () => {
  const v = walkView(walk('before', ['licence', 'pay']), facts());
  assert.equal(v.now?.key, 'sign');
  assert.equal(v.now?.cta?.href, '/account/bookings/CC-10001/sign');
  assert.equal(v.done, 2);
  assert.equal(v.total, 13);
  assert.equal(v.views.find((x) => x.key === 'meet')?.state, 'todo');
});

test('the deposit names the amount and the card; no deposit: the step is left out', () => {
  const v = walkView(walk('before', []), facts());
  assert.match(v.views.find((x) => x.key === 'deposit')!.body, /\$500 on the card ending 4242/);
  const none = walkView(walk('before', [], { deposit: { needed: false } }), facts());
  assert.equal(none.views.some((x) => x.key === 'deposit'), false);
  assert.equal(none.total, 12);
});

test('at pickup: where and when, with the map; the walk-around links the photo report once done', () => {
  const v = walkView(walk('pickup', ['licence', 'sign', 'pay', 'deposit', 'bring']), facts());
  assert.equal(v.now?.key, 'meet');
  assert.match(v.now!.body, /Sat, Apr 11, 10 AM, 1 Example St/);
  assert.equal(v.now?.cta?.label, 'Open in maps');
  const after = walkView(walk('road', ['licence', 'sign', 'pay', 'deposit', 'bring', 'meet', 'inspect']), facts({ status: 'on_rent' }));
  assert.equal(after.views.find((x) => x.key === 'inspect')?.cta?.href, '/account/bookings/CC-10001/condition-report');
  assert.equal(after.now?.key, 'own_photos');
});

test('on the road: the kilometres and fuel from the booking; prepaid fuel says so', () => {
  const r = walkView(walk('road', []), facts()).views.find((x) => x.key === 'rules')!;
  assert.ok(r.points.some((p) => p === '600 km are included; each km over is $0.35'));
  assert.ok(r.points.some((p) => /same fuel level/.test(p)));
  const pre = walkView(walk('road', []), facts({ prepaidFuel: true })).views.find((x) => x.key === 'rules')!;
  assert.ok(pre.points.some((p) => /prepaid/.test(p)));
});

test('a request not confirmed yet: no pay or sign button, and nothing later is "now" before it', () => {
  const v = walkView(walk('before', []), facts({ status: 'requested' }));
  assert.equal(v.views.find((x) => x.key === 'pay')?.cta, undefined);
  assert.equal(v.views.find((x) => x.key === 'sign')?.cta, undefined);
  assert.equal(v.views.find((x) => x.key === 'pay')?.title, 'Pay once we confirm');
  assert.equal(v.now?.key, 'licence');
});

test('everything due done: the next step to come is the one to read now; all done: none', () => {
  const v = walkView(walk('before', ['licence', 'sign', 'pay', 'deposit', 'bring']), facts());
  assert.equal(v.now?.key, 'meet');
  const all = walkView(walk('return', KEYS.map(([k]) => k)), facts({ status: 'closed' }));
  assert.equal(all.now, null);
  assert.equal(all.done, 13);
});
