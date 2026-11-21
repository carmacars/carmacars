// The content calendar's writer (3263): a month of posts with pillars, a format mix, captions, hashtags, best times and
// music; the same input always gives the same calendar; what the results taught leans the next month.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mixOf, monthDays, monthPlan, pillarCycle, postTags, regeneratePost, weekFormats, type Plan } from './calendar.ts';
import type { Facts } from '../ads/social.ts';
import type { CarFacts } from '../ads/listing.ts';

const car = (n: number, daily: number): CarFacts => ({
  vehicle_id: `00000000-0000-4000-8000-00000000000${n}`, car_code: `C${n}`, slug: `car-${n}`, name: `Car ${n}`, year: 2023, make: n % 2 ? 'Toyota' : 'Honda', model: n % 2 ? 'Corolla' : 'Civic',
  taking: true, daily, weekend: daily + 1000, weekly: daily * 6, monthly: daily * 22, deposit: 50000, km: 200, overage: 35, delivery: 7500,
  photos: [{ path: `vehicles/car-${n}/front.jpg` }, { path: `vehicles/car-${n}/side.jpg` }, { path: `vehicles/car-${n}/in.jpg` }]
});
const facts: Facts = { today: '2026-11-20', site_url: 'https://carmacars.ca/', rules: { min_age: 21, standard_min_age: 25, max_days: 30 }, cars: [car(1, 6500), car(2, 8900), car(3, 12000)] };
const plan: Plan = {
  mix: { reel: 2, carousel: 1, photo: 1, story: 1 },
  pillars: [{ code: 'fleet', name: 'Fleet spotlight', weight: 3 }, { code: 'trust', name: 'How renting works', weight: 2 }, { code: 'local', name: 'Toronto and the GTA', weight: 2 },
    { code: 'offers', name: 'Deals and seasons', weight: 2 }, { code: 'owners', name: 'Earn with your car', weight: 1 }, { code: 'proof', name: 'Renter stories', weight: 1 }],
  times: { instagram: ['12:00', '18:30'], facebook_page: ['09:30', '19:00'], tiktok: ['19:00', '21:00'] },
  hashtags: ['#CarmaCars', '#TorontoCarRental', '#GTA'],
  music: { fleet: 'Upbeat', trust: 'Calm', local: 'Warm', offers: 'Bright', owners: 'Steady', proof: 'Happy' }
};

test('a week has the formats of the mix, spread out; the best format of last month leads', () => {
  assert.deepEqual(weekFormats(plan.mix), ['reel', 'carousel', 'reel', 'photo', 'story']);
  assert.equal(weekFormats(plan.mix, 'story')[0], 'story');
  assert.deepEqual(weekFormats({ photo: 1 }), ['photo']);
  assert.equal(weekFormats({ reel: 20 }).length, 7);
});

test('the pillars come up as often as their weight, never the same twice in a row while another is left', () => {
  const c = pillarCycle(plan.pillars);
  assert.equal(c.length, 11);
  assert.equal(c.filter((x) => x === 'fleet').length, 3);
  for (let i = 1; i < c.length; i++) assert.notEqual(c[i], c[i - 1]);
  assert.equal(pillarCycle(plan.pillars, 'owners').filter((x) => x === 'owners').length, 2);
  assert.deepEqual(pillarCycle([]), ['fleet']);
});

test('December: every week of the month has its posts, each complete, in the month, with the plan\'s mix', () => {
  const m = monthPlan(facts, '2026-12', plan);
  assert.equal(monthDays('2026-12').length, 31);
  assert.ok(m.posts.length >= 20 && m.posts.length <= 25, String(m.posts.length));
  const mix = mixOf(m.posts);
  assert.ok(mix.formats.reel! > mix.formats.photo!);
  assert.deepEqual(Object.keys(mix.formats).sort(), ['carousel', 'photo', 'reel', 'story']);
  assert.ok(Object.keys(mix.pillars).length >= 5);
  assert.deepEqual(m.posts.map((p) => p.slot_no), [...new Set(m.posts.map((p) => p.slot_no))]);
  for (const p of m.posts) {
    assert.match(p.slot_date, /^2026-12-\d\d$/);
    assert.ok(p.caption.length > 40 && p.caption.length < 2200, p.caption);
    assert.ok(!/[–—]/.test(p.caption + p.hook), 'no long dash');
    assert.ok(!/\{[a-z]+\}/.test(p.caption + p.hook), `no unfilled value: ${p.caption}`);
    assert.ok(p.hashtags.length >= 3 && p.hashtags.length <= 10 && p.hashtags.every((t) => /^#[A-Za-z0-9]+$/.test(t)), p.hashtags.join(' '));
    assert.ok(p.photos.length >= 1 && p.photos.every((x) => /^vehicles\//.test(x)));
    assert.ok(p.link && p.link.startsWith('https://carmacars.ca/'));
    for (const ch of p.channels) assert.match(p.best_times[ch]!, /^\d\d:\d\d$/);
    if (p.format === 'reel') { assert.deepEqual(p.channels, ['instagram', 'facebook_page', 'tiktok']); assert.ok(p.music && p.vehicle_id); }
    if (p.format === 'story') assert.deepEqual(p.channels, ['instagram']);
    if (p.format === 'photo') assert.equal(p.music, null);
    if (p.format === 'carousel') assert.ok(p.photos.length > 1);
  }
});

test('the same month and facts always give the same calendar; days already past are left out, the slot numbers kept', () => {
  assert.deepEqual(monthPlan(facts, '2026-12', plan), monthPlan(facts, '2026-12', plan));
  const nov = monthPlan(facts, '2026-11', plan);
  assert.ok(nov.posts.length > 0 && nov.posts.every((p) => p.slot_date >= '2026-11-20'));
  const whole = monthPlan(facts, '2026-11', plan, {}, { from: '2026-11-01' });
  assert.deepEqual(nov.posts, whole.posts.filter((p) => p.slot_date >= '2026-11-20'));
});

test('what the results taught leans the next month: the best pillar more often, the best hour on its channel', () => {
  const base = mixOf(monthPlan(facts, '2026-12', plan).posts).pillars;
  const leaned = monthPlan(facts, '2026-12', plan, { top_pillar: 'owners', top_format: 'carousel', times: { instagram: '20:00' } });
  assert.ok(mixOf(leaned.posts).pillars.owners! > base.owners!);
  assert.ok(leaned.posts.filter((p) => p.channels.includes('instagram')).every((p) => p.best_times.instagram === '20:00'));
  assert.ok(leaned.posts.filter((p) => p.channels.includes('tiktok')).every((p) => ['19:00', '21:00'].includes(p.best_times.tiktok!)));
});

test('a car posted lately comes last; with no car that has photos a car post becomes one that needs none', () => {
  const first = monthPlan(facts, '2026-12', plan, {}, { recent: [facts.cars[0]!.vehicle_id] }).posts.find((p) => p.pillar === 'fleet')!;
  assert.notEqual(first.vehicle_id, facts.cars[0]!.vehicle_id);
  const none = monthPlan({ ...facts, cars: [] }, '2026-12', plan);
  assert.ok(none.posts.every((p) => p.pillar !== 'fleet' && p.pillar !== 'offers'));
});

test('Regenerate: the same slot, day, format and pillar, another wording or car', () => {
  const m = monthPlan(facts, '2026-12', plan);
  const p = m.posts.find((x) => x.pillar === 'fleet')!;
  const again = regeneratePost(facts, '2026-12', plan, {}, p.slot_no, 1)!;
  assert.equal(again.slot_no, p.slot_no);
  assert.equal(again.slot_date, p.slot_date);
  assert.equal(again.format, p.format);
  assert.equal(again.pillar, p.pillar);
  assert.ok(again.caption !== p.caption || again.vehicle_id !== p.vehicle_id);
  assert.equal(regeneratePost(facts, '2026-12', plan, {}, 999, 1), null);
});

test('hashtags: the plan\'s, the pillar\'s and the car\'s, no repeats', () => {
  assert.deepEqual(postTags(plan, 'fleet', facts.cars[0]!), ['#CarmaCars', '#TorontoCarRental', '#GTA', '#Toyota', '#ToyotaCorolla']);
  assert.deepEqual(postTags({ ...plan, hashtags: ['CarmaCars', '#CarmaCars'] }, 'owners', null), ['#CarmaCars', '#CarOwners', '#PassiveIncome']);
});
