// Advertising automation (migration 0167): the listing text per channel and its limits, the price line (the same words as
// app.ad_price_line), the week's social drafts, the recruitment templates and Meta publishing with a fake Graph API.
// npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CHANNELS, withUtm } from './channels.ts';
import { ageWords, hashtags, money, priceLine, textProblem, writeListing, type CarFacts, type Rules } from './listing.ts';
import { addDays, captionFor, mondayOf, tripsFor, weekPlan, type Facts } from './social.ts';
import { TEMPLATES, fillTemplate, recruitLink, withStop } from './recruit.ts';
import { publishFacebook, publishInstagram } from '../../integrations/meta.ts';

const rules: Rules = { min_age: 18, standard_min_age: 21, max_days: 30 };
const car = (o: Partial<CarFacts> = {}): CarFacts => ({
  vehicle_id: 'v1', car_code: 'CC-7F3A', slug: 'kia-k5-white', name: '2024 Kia K5', year: 2024, make: 'Kia', model: 'K5', trim: 'GT-Line', colour: 'White', class: 'Midsize',
  seats: 5, transmission: 'Automatic', features: [], allows_18_to_20: true, no_credit_card: false, on_fleet_policy: true, is_featured: false, first_published_at: '2026-10-20T12:00:00Z',
  taking: true, free_this_weekend: true, daily: 7500, weekend: 8500, weekly: 45000, monthly: 160000, deposit: 50000, km: 250, overage: 25, delivery: 4000,
  photos: [{ path: 'cars/v1/1.jpg', label: 'Front three-quarter' }, { path: 'cars/v1/2.jpg', label: 'Side' }, { path: 'cars/v1/3.jpg', label: 'Interior' }], ...o
});
const SITE = 'https://carmacars.ca';
const long = /—| – /;

test('money and the price line say what app.ad_price_line says', () => {
  assert.equal(money(7500), '$75');
  assert.equal(money(160000), '$1,600');
  assert.equal(money(7250), '$72.50');
  assert.equal(priceLine({ daily: 7500, weekly: 45000, monthly: 160000 }), 'From $75 a day, $450 a week, $1,600 for 30 days, plus HST.');
  assert.equal(priceLine({ daily: 7250, weekly: null, monthly: null }), 'From $72.50 a day, plus HST.');
  assert.equal(priceLine({ daily: null, weekly: 100, monthly: null }), '');
});

test('every channel: within its limits, the tracked link, the car code, no long dash, CarmaCars, no claim the record does not hold', () => {
  for (const ch of CHANNELS) {
    const l = writeListing(car(), rules, ch.key, SITE);
    if (ch.titleMax === null) assert.equal(l.title, null, ch.key); else assert.ok(l.title && l.title.length <= ch.titleMax, `${ch.key} title ${l.title}`);
    assert.ok(l.body.length <= ch.bodyMax, ch.key);
    assert.ok(l.photos.length <= ch.photoMax, ch.key);
    assert.ok(l.hashtags.length <= ch.hashtags, ch.key);
    assert.equal(l.link, `https://carmacars.ca/cars/kia-k5-white?utm_source=${ch.key}&utm_medium=${ch.medium}&utm_campaign=CC-7F3A`);
    assert.ok(!long.test(l.body + (l.title ?? '')), `${ch.key}: no long dash`);
    assert.ok(!/18122211|review|rated|best|cheapest/i.test(l.body), `${ch.key}: no fake claim or numbered name`);
    assert.ok(/CarmaCars/.test(l.body + l.bookingNote) || ch.key === 'google_business', `${ch.key}: CarmaCars named`);
    assert.equal(l.priceLine, 'From $75 a day, $450 a week, $1,600 for 30 days, plus HST.');
    assert.deepEqual(l.warnings, []);
    if (ch.linkInText) assert.ok(l.body.includes(l.link), `${ch.key}: the link is in the text`);
  }
});

test('classified text: the spec\'s template, facts only', () => {
  const l = writeListing(car(), rules, 'kijiji', SITE);
  assert.equal(l.title, 'Rent a 2024 Kia K5 in Toronto, from $75 a day');
  assert.match(l.body, /\$75 a day, \$85 a day on weekends, \$450 a week, \$1,600 for 30 days, plus HST\./);
  assert.match(l.body, /250 km a day included, \$0\.25 for each extra km\./);
  assert.match(l.body, /Delivery from \$40 each way, or pick it up yourself\./);
  assert.match(l.body, /You need: age 18 or older \(this car is open to ages 18 to 20\); a G2 or G licence; one coverage option/);
  assert.match(l.body, /a credit card in your name\./);
  assert.match(l.body, /\$500 refundable deposit taken at pickup\./);
  assert.match(l.body, /Rentals up to 30 days\./);
  assert.match(l.body, /Car code CC-7F3A/);
  // a car without the young driver setting, without a card, off the fleet policy: the sentences change or go
  const b = writeListing(car({ allows_18_to_20: false, no_credit_card: true, on_fleet_policy: false, delivery: null }), rules, 'kijiji', SITE).body;
  assert.match(b, /age 21 or older for this car/);
  assert.doesNotMatch(b, /credit card in your name/);
  assert.doesNotMatch(b, /Liability coverage included/);
  assert.match(b, /Pick it up yourself\./);
  assert.match(writeListing(car(), rules, 'fb_marketplace', SITE).body, /^For rent by the day, week or month \(not for sale\)\./);
});

test('a title too long for the channel falls back to a shorter wording, never past the limit', () => {
  const c = car({ make: 'Mercedes-Benz', model: 'GLE 450 4MATIC Coupe', name: '2024 Mercedes-Benz GLE 450 4MATIC Coupe', daily: 32500 });
  const k = writeListing(c, rules, 'kijiji', SITE).title!;
  assert.ok(k.length <= 64, k);
  assert.match(k, /\$325/);
});

test('warnings: not taking requests, no rates, sample photos, no photos', () => {
  assert.ok(writeListing(car({ taking: false }), rules, 'kijiji', SITE).warnings.some((w) => /does not take requests/.test(w)));
  assert.ok(writeListing(car({ daily: null }), rules, 'kijiji', SITE).warnings.some((w) => /no daily rate/.test(w)));
  assert.ok(writeListing(car({ photos: [{ path: '/sample-photos/sedan.jpg', sample: true }] }), rules, 'kijiji', SITE).warnings.some((w) => /sample photos/.test(w)));
  assert.ok(writeListing(car({ photos: [] }), rules, 'kijiji', SITE).warnings.some((w) => /no listing photos/.test(w)));
  assert.equal(writeListing(car({ photos: Array.from({ length: 30 }, (_, i) => ({ path: `p${i}.jpg` })) }), rules, 'google_business', SITE).photos.length, 1);
});

test('Instagram: link in bio (captions cannot hold a link), hashtags; Google: no phone number, a Book button', () => {
  const ig = writeListing(car(), rules, 'instagram', SITE);
  assert.match(ig.body, /Book at the link in bio\./);
  assert.ok(!ig.body.includes('https://'));
  assert.match(ig.bookingNote, /utm_source=instagram/);
  assert.ok(ig.hashtags.includes('#CarmaCars') && ig.hashtags.includes('#KiaK5'));
  const g = writeListing(car(), rules, 'google_business', SITE);
  assert.match(g.body, /^Now available: 2024 Kia K5 from \$75 a day\./);
  assert.doesNotMatch(g.body, /\d{3}[- .]\d{3}[- .]\d{4}/);
  assert.match(g.bookingNote, /^Button: Book, linked to https:\/\/carmacars\.ca\/cars\/kia-k5-white\?utm_source=google_business/);
  assert.equal(ageWords(car({ allows_18_to_20: false }), rules), 'age 21 or older for this car');
  assert.deepEqual(hashtags(car(), 0), []);
});

test('text check: long dashes and the numbered company name are refused', () => {
  assert.ok(textProblem('Fast — cheap'));
  assert.ok(textProblem('A – B'));
  assert.ok(textProblem('18122211 Canada Inc.'));
  assert.equal(textProblem('CarmaCars, Toronto'), null);
  assert.ok(textProblem('  '));
});

test('the week\'s drafts: Monday a new car, Tuesday the owner program, Thursday the weekend, Friday the requirements, Sunday a highlight', () => {
  const f: Facts = { today: '2026-10-26', site_url: SITE, rules, cars: [car(), car({ vehicle_id: 'v2', slug: 'civic', name: '2022 Honda Civic', make: 'Honda', model: 'Civic', year: 2022, daily: 6000, first_published_at: '2026-01-01T00:00:00Z', free_this_weekend: false }),
    car({ vehicle_id: 'v3', slug: 'off', taking: false })] };
  const mon = mondayOf('2026-10-28');
  assert.equal(mon, '2026-10-26');
  const w = weekPlan(f, mon);
  const by = Object.fromEntries(w.map((d) => [d.kind, d]));
  assert.equal(by.new_car?.slot_date, '2026-10-26');
  assert.equal(by.new_car?.vehicle_id, 'v1', 'published in the 14 days before');
  assert.match(by.new_car!.caption, /2024 Kia K5/);
  assert.match(by.new_car!.caption, /\$75 a day/);
  assert.equal(by.owner_program?.slot_date, '2026-10-27');
  assert.match(by.owner_program!.caption, /fleet insurance policy/);
  assert.match(by.owner_program!.caption, /Fees apply/);
  assert.equal(by.weekend_list?.slot_date, '2026-10-29');
  assert.match(by.weekend_list!.caption, /2024 Kia K5, from \$75 a day/);
  assert.doesNotMatch(by.weekend_list!.caption, /Civic/, 'not free this weekend');
  assert.deepEqual(by.requirements?.channels, ['instagram']);
  assert.ok(by.price_highlight || by.seasonal);
  for (const d of w) { assert.ok(!long.test(d.caption), d.kind); assert.ok(d.caption.length <= 2200); assert.ok(!/\bv3\b/.test(d.vehicle_id ?? '')); }
  // the same week always reads the same; days before today are left out
  assert.deepEqual(weekPlan(f, mon), w);
  assert.ok(weekPlan(f, mon, '2026-10-28').every((d) => d.slot_date >= '2026-10-28'));
  // no car taking requests: only the owner program and the requirements
  assert.deepEqual(weekPlan({ ...f, cars: [] }, mon).map((d) => d.kind).sort(), ['owner_program', 'requirements']);
  assert.equal(addDays('2026-12-31', 1), '2027-01-01');
  assert.ok(tripsFor('2027-01-10').every((t) => t.season !== 'summer'));
  assert.ok(tripsFor('2026-10-10').every((t) => !t.season));
});

test('captions per channel: the tracked link, in the text on the Facebook Page, link in bio on Instagram', () => {
  const link = 'https://carmacars.ca/cars/kia-k5-white';
  const tracked = withUtm(link, 'facebook_page', 'social', 'CC-7F3A');
  const cap = '2024 Kia K5.\n\nBook at the link in bio.';
  assert.equal(captionFor(cap, 'instagram', link, withUtm(link, 'instagram', 'social', 'CC-7F3A')), cap);
  assert.equal(captionFor(cap, 'facebook_page', link, tracked), `2024 Kia K5.\n\nBook or check the calendar: ${tracked}`);
  assert.equal(captionFor(`See it: ${link}`, 'facebook_page', link, tracked), `See it: ${tracked}`);
});

test('recruitment templates: filled for the lead, the tracked link, CarmaCars named, the STOP line for texts', () => {
  for (const t of TEMPLATES) {
    const f = fillTemplate(t, { first_name: 'Sam', vehicle: '2021 Honda Civic', sender: 'Priya', phone: '289-312-5991', link: recruitLink(SITE, t.channel), referrer: 'Olive', business: 'Test Auto' });
    assert.ok(!/\{\w+\}/.test(f.body + f.subject), `${t.key}: no placeholder left`);
    assert.match(f.body, /CarmaCars/);
    assert.ok(!long.test(f.body + f.subject), t.key);
    assert.match(f.body, /utm_source=recruit/);
    if (t.channel === 'text') assert.ok(withStop(f.body).length <= 480, t.key);
  }
  assert.equal(withStop('CarmaCars: hi.'), 'CarmaCars: hi. Reply STOP to opt out.');
  assert.equal(withStop('CarmaCars. Reply STOP to opt out.'), 'CarmaCars. Reply STOP to opt out.');
  assert.match(fillTemplate(TEMPLATES[0]!, {}).body, /The CarmaCars team/);
});

test('Meta publishing: a photo post on the Page, a container then a publish on Instagram, refusals as errors', async () => {
  const calls: string[] = [];
  const f = (async (url: string, init?: RequestInit) => {
    calls.push(`${init?.method ?? 'GET'} ${String(url).replace(/\?.*$/, '')} ${init?.body ? String(init.body).replace(/access_token=[^&]+/, 'access_token=x') : ''}`);
    const u = String(url);
    const json = u.includes('/photos') ? { id: '9', post_id: '100_9' } : u.includes('/media_publish') ? { id: 'ig9' } : u.includes('/media') ? { id: 'c1' } : u.includes('/feed') ? { id: '100_7' } : { permalink: 'https://www.instagram.com/p/x/' };
    return new Response(JSON.stringify(json), { status: 200 });
  }) as unknown as typeof fetch;
  const cfg = { pageId: '100', igUserId: '178', token: 'EAAsecret', version: 'v21.0' };
  assert.deepEqual(await publishFacebook(cfg, { message: 'Hi', link: 'https://carmacars.ca/cars', imageUrl: 'https://photos.example/a.jpg' }, f), { postId: '100_9', url: 'https://www.facebook.com/100_9' });
  assert.deepEqual(await publishFacebook(cfg, { message: 'Hi', link: 'https://carmacars.ca/cars', imageUrl: null }, f), { postId: '100_7', url: 'https://www.facebook.com/100_7' });
  assert.deepEqual(await publishInstagram(cfg, { caption: 'Hi', imageUrl: 'https://photos.example/a.jpg' }, f), { postId: 'ig9', url: 'https://www.instagram.com/p/x/' });
  assert.ok(calls[0]!.startsWith('POST https://graph.facebook.com/v21.0/100/photos url=https'));
  assert.ok(calls.some((c) => c.startsWith('POST https://graph.facebook.com/v21.0/178/media image_url=')));
  assert.ok(calls.some((c) => c.includes('/178/media_publish creation_id=c1')));
  assert.ok(calls.every((c) => !c.includes('EAAsecret')), 'the token is sent, never kept in what is logged here');
  await assert.rejects(publishInstagram({ ...cfg, igUserId: null }, { caption: 'x', imageUrl: 'https://a/b.jpg' }, f), /Instagram account id/);
  await assert.rejects(publishInstagram(cfg, { caption: 'x', imageUrl: null }, f), /needs a photo/);
  const bad = (async () => new Response(JSON.stringify({ error: { message: 'Invalid OAuth access token.' } }), { status: 400 })) as unknown as typeof fetch;
  await assert.rejects(publishFacebook(cfg, { message: 'x', link: null, imageUrl: null }, bad), /Meta: Invalid OAuth access token/);
});
