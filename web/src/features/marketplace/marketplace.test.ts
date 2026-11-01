// Facebook Marketplace kits (migration 0410): the kit's fields, description and photo order, the rotation of what to post
// or renew each day, and the inbox replies. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { CarFacts, Rules } from '../ads/listing.ts';
import { bestPhotos, bodyStyle, buildKit, colour, condition, fuelType, location, mileage } from './kit.ts';
import { addDays, marketplacePlan, type MpCar, type MpPosting } from './plan.ts';
import { replies } from './replies.ts';

const rules: Rules = { min_age: 18, standard_min_age: 21, max_days: 30 };
const settings = { posts_per_day: 4, renew_days: 7, location: 'Toronto, Ontario' };
const SITE = 'https://carmacars.ca';
const car = (o: Partial<CarFacts> = {}): CarFacts => ({
  vehicle_id: 'v1', car_code: 'CC-7F3A', slug: 'kia-k5-white', name: '2024 Kia K5', year: 2024, make: 'Kia', model: 'K5', trim: 'GT-Line', colour: 'Pearl White', class: 'Midsize',
  body_style: 'Sedan', fuel: 'Gasoline', seats: 5, transmission: 'Automatic', features: [], allows_18_to_20: true, no_credit_card: false, on_fleet_policy: true, is_featured: false,
  first_published_at: '2026-10-20T12:00:00Z', taking: true, free_this_weekend: true, daily: 7500, weekend: 8500, weekly: 45000, monthly: 160000, deposit: 50000, km: 250, overage: 25, delivery: 7500,
  photos: [{ path: 'c/1.jpg', shot: 'front_left' }, { path: 'c/2.jpg', shot: 'wheel' }, { path: 'c/3.jpg', shot: 'rear' }, { path: 'c/4.jpg', shot: 'dashboard' }, { path: 'c/5.jpg', shot: 'front_seats' },
    { path: 'c/6.jpg', shot: 'other' }, { path: 'c/7.jpg', shot: 'left' }, { path: 'c/8.jpg', shot: 'trunk' }, { path: 'c/9.jpg', shot: 'right' }, { path: 'c/10.jpg', shot: 'rear_seats' },
    { path: 'c/11.jpg', shot: 'front' }, { path: 'c/12.jpg', shot: 'rear_right' }], ...o
});
const long = /—| – /;

test('the kit fills the vehicle form in its order, from the car\'s record', () => {
  const k = buildKit(car(), rules, { odometer_km: 41234, home_area: 'Mississauga' }, settings, SITE, '2026-11-01');
  assert.deepEqual(k.fields.map((f) => f.label), ['Vehicle type', 'Location', 'Year', 'Make', 'Model', 'Mileage (km)', 'Price', 'Body style', 'Exterior colour', 'Interior colour', 'Clean title', 'Vehicle condition', 'Fuel type', 'Transmission']);
  const v = Object.fromEntries(k.fields.map((f) => [f.label, f.value]));
  assert.equal(v['Vehicle type'], 'Car/Truck');
  assert.equal(v.Location, 'Mississauga, Ontario');
  assert.equal(v['Mileage (km)'], '42000');
  assert.equal(v.Price, '75');
  assert.equal(v['Body style'], 'Sedan');
  assert.equal(v['Exterior colour'], 'Off white');
  assert.equal(v['Vehicle condition'], 'Excellent');
  assert.equal(v.Transmission, 'Automatic transmission');
  assert.equal(k.blockers.length, 0);
  assert.equal(k.link, 'https://carmacars.ca/cars/kia-k5-white?utm_source=fb_marketplace&utm_medium=marketplace&utm_campaign=CC-7F3A');
});

test('the description: booked by the day, not for sale, rates, requirements, the link and the next step; no long dash', () => {
  const k = buildKit(car(), rules, {}, settings, SITE, '2026-11-01');
  assert.match(k.description, /^Book this 2024 Kia K5 GT-Line by the day, from \$75\/day\.\nDaily and weekly bookings only, not for sale\.\nPearl White, 5 seats, automatic\.\n/);
  assert.match(k.description, /\nDaily and weekly bookings only, not for sale\.\n/);
  assert.match(k.description, /Free this weekend: drive it today\./);
  assert.equal(k.title, 'Book this 2024 Kia K5 by the day, from $75/day');
  assert.match(k.description, /\$75 a day, \$85 a day on weekends, \$450 a week, \$1,600 for 30 days, plus HST\./);
  assert.match(k.description, /250 km a day included, \$0\.25 for each extra km\./);
  assert.match(k.description, /Delivery across Ontario from \$75 each way/);
  assert.match(k.description, /\$500 refundable deposit hold on pickup day\./);
  assert.match(k.description, /utm_source=fb_marketplace/);
  assert.match(k.description, /message your phone number/);
  assert.match(k.description, /Car code CC-7F3A\./);
  assert.doesNotMatch(k.description, long);
  assert.doesNotMatch(k.descriptionNoLink, /https?:/);
  assert.equal(k.location, 'Toronto, Ontario');
});

test('no "rent", "rental" or "for rent" anywhere a buyer reads (the owner, November 1, 2026)', () => {
  const c = car();
  const k = buildKit(c, rules, {}, settings, SITE, '2026-11-01');
  const texts = [k.title, k.description, k.descriptionNoLink, ...k.fields.map((f) => `${f.value} ${f.note ?? ''}`), ...replies(c, rules, k.link, '289-312-5991').map((r) => r.text)];
  for (const t of texts) assert.doesNotMatch(t, /\brent(al|als|ed|ing)?\b/i, t);
  assert.ok(texts.slice(1, 3).every((t) => /not for sale/.test(t)));
  assert.match(replies(c, rules, k.link, null)[0]!.text, /not for sale/);
});

test('the ten best photos: the cover, then the shots buyers look for; never a sample', () => {
  const p = bestPhotos(car().photos);
  assert.equal(p.length, 10);
  assert.deepEqual(p.slice(0, 5).map((x) => x.shot), ['front_left', 'front', 'dashboard', 'front_seats', 'rear_seats']);
  assert.ok(!p.some((x) => x.shot === 'other'));
  const samples = buildKit(car({ photos: [{ path: '/sample-photos/sedan.jpg', sample: true }] }), rules, {}, settings, SITE, '2026-11-01');
  assert.deepEqual(samples.photos, []);
  assert.match(samples.blockers.join(), /sample photos/);
});

test('mapping the record to Marketplace\'s lists', () => {
  assert.equal(bodyStyle('Sport utility'), 'SUV');
  assert.equal(bodyStyle('Convertible'), 'Convertible');
  assert.equal(bodyStyle('Hatchback'), 'Hatchback');
  assert.equal(bodyStyle(null), 'Other');
  assert.equal(colour('Graphite grey'), 'Grey');
  assert.equal(colour('Black'), 'Black');
  assert.equal(colour('Mango'), 'Other');
  assert.equal(fuelType('Plug-in hybrid'), 'Plug-in hybrid');
  assert.equal(fuelType('Hybrid'), 'Hybrid');
  assert.equal(fuelType(null), 'Gasoline');
  assert.equal(condition(2019, '2026-11-01'), 'Very good');
  assert.equal(mileage(0), null);
  assert.equal(mileage(1000), 1000);
  assert.equal(location({ home_area: 'Hamilton, Ontario' }, settings), 'Hamilton, Ontario');
});

test('a car that cannot be posted says why', () => {
  const k = buildKit(car({ taking: false, daily: null }), rules, { supply: 'partner' }, settings, SITE, '2026-11-01');
  assert.deepEqual(k.blockers, ['Not taking requests on the site', 'No daily rate']);
  assert.match(k.warnings.join(), /partner/);
  assert.match(k.warnings.join(), /odometer/);
});

const cars = (n: number, o: Partial<MpCar> = {}): MpCar[] => Array.from({ length: n }, (_, i) => ({ vehicle_id: `v${i + 1}`, name: `Car ${String(i + 1).padStart(2, '0')}`, blocked: false, partner: false, featured: false, ...o }));
const live = (id: string, posted: string, o: Partial<MpPosting> = {}): MpPosting => ({ vehicle_id: id, status: 'live', posted_on: posted, needs_update: false, ...o });

test('the rotation: at most the day\'s allowance of new posts and renewals, updates and take-downs at once', () => {
  const today = '2026-11-01';
  const list = cars(10);
  list[9]!.blocked = true;
  const p = marketplacePlan(list, [live('v1', '2026-10-20'), live('v2', '2026-10-30', { needs_update: true, update_reason: 'Daily rate $75 to $89' }), live('v10', '2026-10-15')],
    { today, perDay: 4, renewDays: 7, done: 0 });
  assert.deepEqual(p.today.slice(0, 2).map((x) => [x.action, x.vehicle_id]), [['update', 'v2'], ['remove', 'v10']]);
  const capped = p.today.filter((x) => x.action === 'post' || x.action === 'renew');
  assert.equal(capped.length, 4);
  assert.ok(capped.every((x) => x.action === 'post'), 'new posts first');
  assert.equal(p.waiting, 7);
  // tomorrow and after: the rest of the posts, then v1's overdue renewal
  const all = p.later.flatMap((d) => d.items);
  assert.ok(p.later.every((d) => d.items.length <= 4));
  assert.ok(all.some((x) => x.vehicle_id === 'v1' && x.action === 'renew'));
  assert.equal(all.filter((x) => x.action === 'post').length, 3);
  // posted today: renewed after 7 days
  assert.ok(all.some((x) => x.vehicle_id === capped[0]!.vehicle_id && x.action === 'renew' && x.due === addDays(today, 7)));
});

test('what was done today counts against the day; partners after our own cars', () => {
  const list = [...cars(2), { vehicle_id: 'p1', name: 'A partner car', blocked: false, partner: true, featured: true }];
  const p = marketplacePlan(list, [], { today: '2026-11-01', perDay: 3, renewDays: 7, done: 2 });
  assert.equal(p.left_today, 1);
  assert.deepEqual(p.today.map((x) => x.vehicle_id), ['v1']);
  assert.equal(p.later[0]!.items.at(-1)!.vehicle_id, 'p1');
  const none = marketplacePlan(cars(2), [live('v1', '2026-10-31'), live('v2', '2026-10-31')], { today: '2026-11-01', perDay: 4, renewDays: 7, done: 0 });
  assert.equal(none.today.length, 0);
  assert.equal(none.later[0]!.date, '2026-11-07');
});

test('the replies: every one ends on carmacars.ca or a phone number, with the car\'s facts', () => {
  const c = car();
  const k = buildKit(c, rules, {}, settings, SITE, '2026-11-01');
  const rs = replies(c, rules, k.link, '289-312-5991');
  assert.deepEqual(rs.map((r) => r.key), ['available', 'price', 'availability', 'requirements', 'deposit', 'delivery', 'number', 'after_number']);
  for (const r of rs) {
    assert.ok(/utm_content=reply/.test(r.text), `${r.key}: the tracked link`);
    assert.ok(/number|request|book/i.test(r.text), `${r.key}: the next step`);
    assert.doesNotMatch(r.text, long);
  }
  assert.match(rs.find((r) => r.key === 'price')!.text, /\$75 a day/);
  assert.match(rs.find((r) => r.key === 'deposit')!.text, /\$500/);
  assert.match(rs.find((r) => r.key === 'requirements')!.text, /age 18 or older/);
  assert.match(rs.find((r) => r.key === 'number')!.text, /289-312-5991/);
});
