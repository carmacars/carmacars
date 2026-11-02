// Sales's Marketing tab (migration 0510): copy variants that never repeat a title, a description or a cover, the honest
// wording in every variant, a salesperson's day, and the instructions for their own Claude. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { CarFacts, Rules } from '../ads/listing.ts';
import { buildKit } from './kit.ts';
import { freeVariant, teamPlan, type TeamCar, type TeamClaim } from './team.ts';
import { MAX_VARIANT, NOT_FOR_SALE, variantCount, variantKit } from './variants.ts';
import { claudePrompt } from './prompt.ts';

const rules: Rules = { min_age: 18, standard_min_age: 21, max_days: 30 };
const settings = { posts_per_day: 4, renew_days: 7, location: 'Toronto, Ontario' };
const car = (o: Partial<CarFacts> = {}): CarFacts => ({
  vehicle_id: 'v1', car_code: 'CC-7F3A', slug: 'kia-k5-white', name: '2024 Kia K5', year: 2024, make: 'Kia', model: 'K5', trim: 'GT-Line', colour: 'Pearl White', class: 'Midsize',
  body_style: 'Sedan', fuel: 'Gasoline', seats: 5, transmission: 'Automatic', features: [], allows_18_to_20: true, no_credit_card: false, on_fleet_policy: true, is_featured: false,
  first_published_at: '2026-10-20T12:00:00Z', taking: true, free_this_weekend: true, daily: 7500, weekend: 8500, weekly: 45000, monthly: 160000, deposit: 50000, km: 250, overage: 25, delivery: 7500,
  photos: Array.from({ length: 12 }, (_, i) => ({ path: `c/${i + 1}.jpg`, shot: i === 0 ? 'front_left' : 'other' })), ...o
});
const rent = /\b(rent|rental|rentals|renting)\b/i;

test('every variant has its own title, description and cover; the wording rule holds in each', () => {
  for (const c of [car(), car({ daily: null, photos: car().photos.slice(0, 10) })]) {
    const k = buildKit(c, rules, {}, settings, 'https://carmacars.ca', '2026-11-02');
    const vs = Array.from({ length: Math.min(MAX_VARIANT, k.photos.length) }, (_, i) => variantKit(k, c, i + 1));
    assert.equal(vs[0]!.description, k.description, 'variant 1 is the owner\'s kit unchanged');
    for (const key of ['title', 'description', 'descriptionNoLink', 'cover', 'link'] as const) assert.equal(new Set(vs.map((v) => v[key])).size, vs.length, `${key} repeats`);
    for (const v of vs) {
      assert.ok(!rent.test(v.title) && !rent.test(v.description), `variant ${v.variant} says rent`);
      assert.equal(v.description.split('\n')[1], NOT_FOR_SALE, `variant ${v.variant}`);
      assert.ok(!/—| – /.test(v.description));
      assert.equal(v.photos.length, k.photos.length, 'every photo kept');
      assert.equal(v.cover, v.photos[0]!.path);
      if (v.variant > 1) { assert.ok(v.description.includes(v.link)); assert.ok(!v.descriptionNoLink.includes('http')); assert.match(v.link, new RegExp(`utm_content=v${v.variant}`)); }
    }
  }
  assert.equal(variantCount(3, 5), 3, 'one cover a variant: three photos, three variants');
  assert.equal(variantCount(12, 5), 5);
});

const now = '2026-11-02T15:00:00.000Z';
const claim = (o: Partial<TeamClaim>): TeamClaim => ({ id: 'c', vehicle_id: 'v1', variant: 2, status: 'live', poster_id: 'me', poster: null, title: 't', cover: 'x', price_line: 'From $75 a day, plus HST.',
  url: 'https://www.facebook.com/marketplace/item/1/', claimed_at: now, posted_on: '2026-10-20', renewed_on: '2026-10-20', expires_at: '2026-11-19T04:59:00.000Z', ...o });
const cars: TeamCar[] = [
  { vehicle_id: 'v1', name: 'Kia K5', blocked: false, featured: false, photos: 10, priceLine: 'From $75 a day, plus HST.' },
  { vehicle_id: 'v2', name: 'Honda CR-V', blocked: false, featured: true, photos: 10, priceLine: 'p' },
  { vehicle_id: 'v3', name: 'Toyota Camry', blocked: false, featured: false, photos: 2, priceLine: 'p' },
  { vehicle_id: 'v4', name: 'Audi Q5', blocked: true, featured: false, photos: 10, priceLine: 'p' }
];
const o = { today: '2026-11-02', now, perDay: 2, renewDays: 7, done: 0, maxLive: 5 };

test('free variants: never one taken, never over the limit, one cover each', () => {
  const team = [claim({ variant: 2, poster_id: 'a' }), claim({ variant: 3, poster_id: 'b' }), claim({ variant: 4, poster_id: 'c', status: 'ended' }), claim({ variant: 5, poster_id: 'd', expires_at: '2026-11-01T00:00:00Z' })];
  assert.equal(freeVariant(cars[0]!, team, true, 5, now), 4, 'ended and lapsed listings free their variant');
  assert.equal(freeVariant(cars[0]!, [...team, claim({ variant: 4, poster_id: 'e' }), claim({ variant: 5, poster_id: 'f' })], true, 5, now), null, 'five up with the owner\'s');
  assert.equal(freeVariant(cars[2]!, [claim({ vehicle_id: 'v3', variant: 2, poster_id: 'a' })], false, 5, now), null, 'two photos: two covers, both used');
});

test('my day: edits first, then renewals due, then new posts on the emptiest cars, within my allowance', () => {
  const team = [claim({ id: 'mine', poster_id: 'me' }), claim({ id: 'x', vehicle_id: 'v2', poster_id: 'other', variant: 2 })];
  const p = teamPlan(cars, team, 'me', new Set(['v2']), o);
  assert.deepEqual(p.today.map((x) => `${x.action}:${x.vehicle_id}:${x.variant}`), ['renew:v1:2', 'post:v3:2'], 'the Camry has no listing yet, the CR-V has two');
  assert.equal(p.mine_live, 1);
  const changed = teamPlan(cars.map((c) => (c.vehicle_id === 'v1' ? { ...c, priceLine: 'From $79 a day, plus HST.' } : c)), team, 'me', new Set(), o);
  assert.equal(changed.today[0]!.action, 'update');
  const claimed = teamPlan(cars, [claim({ id: 'n', poster_id: 'me', status: 'claimed', posted_on: null, url: null })], 'me', new Set(), { ...o, done: 2 });
  assert.deepEqual(claimed.today.map((x) => x.action), ['finish'], 'a claim to finish is always due; nothing new past the allowance');
  const off = teamPlan(cars, [claim({ vehicle_id: 'v4', poster_id: 'me' })], 'me', new Set(), o);
  assert.equal(off.today[0]!.action, 'remove');
});

test('the instructions for my own Claude mirror the playbook', () => {
  const t = claudePrompt('https://carmacars.ca');
  assert.ok(t.includes('https://carmacars.ca/staff/marketing'));
  for (const must of ['Never write "rent", "rental" or "for rent"', 'Daily and weekly bookings only, not for sale', 'Never type or ask for a password', 'CAPTCHA', 'Log every post',
    'reply templates only', 'Never post the same car twice']) assert.ok(t.includes(must), must);
  assert.ok(!/—| – /.test(t));
});
