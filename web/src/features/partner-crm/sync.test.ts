import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGhl, redact, GhlError } from './ghl.ts';
import { fakeGhlFetch, fakeState, type FakeState } from './fake-ghl.ts';
import { runSync, testConnection, type Job, type Connection } from './sync.ts';
import { OBJECT_FIELDS, bookedRuns, feedCsv, feedRow, fromFeed, parseName, payloadHash, photoUrls, recordProperties, shareable, toCents, type OutboundCar } from './mapping.ts';
import { feedKey, feedKeyOk } from './feed-key.ts';
import { renderWidget } from './widget.ts';

// The partner CRM link (migration 0136) against the GoHighLevel stand-in: our cars out (a custom object, or products
// when the plan has none), their cars in, leads both ways, Test connection, the rate limit and the version, and the
// owner's rule that a partner car never goes to a partner. Fictional data only.

const TOKEN = 'pit-1234abcd-0000-4000-8000-feedfacecafe';
const LOC = 'loc01motorsFAKE';
const noSleep = async () => {};
const ghlFor = (state: FakeState, token = TOKEN, f?: typeof fetch) => createGhl({ token, locationId: LOC, fetch: f ?? fakeGhlFetch(state), sleep: noSleep });

function car(id: string, over: Partial<OutboundCar> = {}): OutboundCar {
  return {
    vehicle_id: id, car_code: `CC-${id.toUpperCase()}`, supply_type: 'company', name: `2024 BMW X5 ${id}`, year: 2024, make: 'BMW', model: 'X5', trim: 'xDrive40i', colour: 'Black',
    class: 'suv', seats: '5', doors: '4', body_style: 'SUV', transmission: 'Automatic', slug: `bmw-x5-${id}`, location: 'Yorkville, Toronto',
    car_url: `https://carmacars.ca/cars/bmw-x5-${id}`, book_url: `https://carmacars.ca/p/01-motors/bmw-x5-${id}`, photos: [`vehicles/${id}-lead.jpg`, '/sample-photos/x.svg'],
    daily_cents: 18900, weekly_cents: 112000, monthly_cents: 390000,
    availability: { available_today: true, next_free_date: '2026-10-24', free_days_30: 27, free_days_60: 55, booked: [{ from: '2026-11-01', to: '2026-11-03' }] }, ...over
  };
}
function conn(over: Partial<Connection> = {}): Connection {
  return { id: 'conn-1', partner_id: 'partner-1', partner: '01 Motors', location_id: LOC, api_version: '2021-07-28', enabled: true, share_cars: true,
    outbound_target: 'auto', detected_target: null, object_key: 'carmacars_vehicles', inbound_enabled: true, inbound_source: 'auto', inbound_object_key: null,
    inbound_feed_url: null, leads_enabled: false, pipeline_id: null, pipeline_stage_id: null, inbound_stage_id: null, referral_code: '01-motors', ...over };
}
function job(over: Partial<Job> = {}): Job {
  return { run_id: 'run-1', connection: conn(), cars: [car('a'), car('b', { supply_type: 'program_owner' })], records: [], leads: [], known_opportunities: [],
    site: { url: 'https://carmacars.ca', name: 'CarmaCars' }, ...over };
}
const deps = (ghl: ReturnType<typeof createGhl>) => ({ ghl, bucketUrl: (p: string) => `https://photos.example.test/${p}` });

test('our cars go out as a "CarmaCars Vehicles" custom object: the object, its fields and one record per car', async () => {
  const s = fakeState();
  const r = await runSync(job(), deps(ghlFor(s)));
  assert.equal(r.ok, true, r.error ?? '');
  assert.equal(r.target, 'custom_object');
  assert.ok(s.objects.has('custom_objects.carmacars_vehicles'));
  assert.equal(s.fields.get('custom_objects.carmacars_vehicles')!.length, OBJECT_FIELDS.length + 1, 'every field and the primary one');
  const recs = [...s.records.get('custom_objects.carmacars_vehicles')!.values()];
  assert.equal(recs.length, 2);
  const a = recs.find((x) => x.properties.car_code === 'CC-A')!;
  assert.equal(a.properties.daily_rate, 189);
  assert.equal(a.properties.weekly_rate, 1120);
  assert.equal(a.properties.next_free_date, '2026-10-24');
  assert.equal(a.properties.booked_dates, '2026-11-01 to 2026-11-03');
  assert.equal(a.properties.book_url, 'https://carmacars.ca/p/01-motors/bmw-x5-a');
  assert.equal(a.properties.cover_photo, 'https://photos.example.test/vehicles/a-lead.jpg');
  assert.match(String(a.properties.photo_urls), /https:\/\/carmacars\.ca\/sample-photos\/x\.svg/);
  assert.deepEqual(r.counts.created, 2);
  assert.equal(r.records.length, 2);
  // every call carried the token as a bearer and a version
  assert.ok(s.log.every((l) => l.auth?.startsWith('Bearer pit-') && l.version));
});

test('a second run sends nothing unchanged; a changed car is updated; a car no longer shared is removed', async () => {
  const s = fakeState();
  const first = await runSync(job(), deps(ghlFor(s)));
  const records = first.records.map((x) => ({ ...x }));
  const second = await runSync(job({ records, connection: conn({ detected_target: 'custom_object' }) }), deps(ghlFor(s)));
  assert.equal(second.counts.unchanged, 2);
  assert.equal(second.counts.created, 0);
  const third = await runSync(job({ records, cars: [car('a', { daily_cents: 19900 })], connection: conn({ detected_target: 'custom_object' }) }), deps(ghlFor(s)));
  assert.equal(third.counts.updated, 1);
  assert.equal(third.counts.removed, 1);
  assert.deepEqual(third.removed, [{ vehicle_id: 'b', remote_kind: 'object_record' }]);
  const recs = [...s.records.get('custom_objects.carmacars_vehicles')!.values()];
  assert.equal(recs.length, 1);
  assert.equal(recs[0]!.properties.daily_rate, 199);
});

test('THE RULE: a partner car is never sent to a partner, even if the job carried one', async () => {
  const s = fakeState();
  const partnerCar = car('p', { supply_type: 'partner', car_code: 'CC-PARTNER', name: '2025 Mercedes G63 AMG (01 Motors)' });
  const r = await runSync(job({ cars: [car('a'), partnerCar] }), deps(ghlFor(s)));
  assert.equal(r.counts.refused, 1);
  assert.equal(r.counts.cars, 1);
  const sent = JSON.stringify([...s.records.values()].flatMap((m) => [...m.values()]));
  assert.ok(!sent.includes('CC-PARTNER') && !sent.includes('01 Motors)'), 'no partner car in their CRM');
  assert.ok(!r.records.some((x) => x.vehicle_id === 'p'));
  assert.deepEqual(shareable([partnerCar]).cars, []);
  // the products path too
  const s2 = fakeState();
  await runSync(job({ cars: [partnerCar], connection: conn({ outbound_target: 'products' }) }), deps(ghlFor(s2)));
  assert.equal(s2.products.size, 0);
});

test('no custom objects on their plan: products with a daily price instead', async () => {
  const s = fakeState();
  const r = await runSync(job(), deps(ghlFor(s, 'pit-noobjects-1234-abcd-ef00')));
  assert.equal(r.ok, true, r.error ?? '');
  assert.equal(r.target, 'products');
  assert.equal(s.products.size, 2);
  const p = [...s.products.values()].find((x) => x.name.includes('CC-A'))!;
  assert.match(p.description!, /Partner rates: \$189 a day/);
  assert.match(p.description!, /Book: https:\/\/carmacars\.ca\/p\/01-motors\/bmw-x5-a/);
  assert.equal(p.image, 'https://photos.example.test/vehicles/a-lead.jpg');
  const prices = s.prices.get(p._id)!;
  assert.deepEqual([prices.length, prices[0]!.amount, prices[0]!.currency], [1, 189, 'CAD']);
  // the price follows the rate
  const again = await runSync(job({ cars: [car('a', { daily_cents: 20900 })], records: r.records, connection: conn({ detected_target: 'products' }) }), deps(ghlFor(s, 'pit-noobjects-1234-abcd-ef00')));
  assert.equal(again.counts.updated, 1);
  assert.equal(s.prices.get(p._id)![0]!.amount, 209);
  assert.equal(s.products.size, 1, 'the other car was removed');
});

test('a refused token: a plain error, and the token never appears in it', async () => {
  const s = fakeState();
  const bad = 'pit-bad-9999-secret-value-abc';
  const r = await runSync(job(), deps(ghlFor(s, bad)));
  assert.equal(r.ok, false);
  assert.match(r.error!, /token was refused/);
  assert.ok(!r.error!.includes(bad));
  const t = await testConnection(ghlFor(s, bad));
  assert.equal(t.ok, false);
  assert.ok(!JSON.stringify(t).includes(bad));
  assert.equal(redact(`Bearer ${bad} and ${bad}`, bad), 'Bearer [token] and [token]');
  assert.equal(redact('oops pit-abcdef123456 here'), 'oops pit-[token] here');
});

test('the rate limit: a 429 waits (Retry-After) and tries again; the burst headers are read', async () => {
  const s = fakeState();
  const waits: number[] = [];
  const ghl = createGhl({ token: 'pit-slow-1234-abcd-ef00-0000', locationId: LOC, fetch: fakeGhlFetch(s), sleep: async (ms) => { waits.push(ms); } });
  const loc = await ghl.location();
  assert.equal(loc.name, '01 Motors (test CRM)');
  assert.equal(waits.length, 1);
  // a nearly used window waits before the next call
  let calls = 0;
  const tight = createGhl({ token: TOKEN, locationId: LOC, sleep: async (ms) => { waits.push(ms); }, fetch: (async () => {
    calls++;
    return new Response(JSON.stringify({ location: { id: LOC } }), { status: 200, headers: { 'x-ratelimit-remaining': '1', 'x-ratelimit-interval-milliseconds': '10000' } });
  }) as typeof fetch });
  await tight.location(); await tight.location();
  assert.equal(calls, 2);
  assert.equal(waits.at(-1), 10000);
});

test('custom objects: the other Version is tried when the first one is refused for its version', async () => {
  const s = fakeState();
  const inner = fakeGhlFetch(s);
  const seen: string[] = [];
  const f = (async (u: RequestInfo | URL, init?: RequestInit) => {
    const v = new Headers(init?.headers).get('version') ?? '';
    if (String(u).includes('/objects')) { seen.push(v); if (v !== 'v3') return new Response(JSON.stringify({ statusCode: 400, message: 'Unsupported version for this endpoint' }), { status: 400 }); }
    return inner(u, init);
  }) as typeof fetch;
  const ghl = createGhl({ token: TOKEN, locationId: LOC, fetch: f, sleep: noSleep });
  const objs = await ghl.listObjects();
  assert.ok(objs.length >= 1);
  await ghl.listObjects();
  assert.deepEqual(seen, ['2021-07-28', 'v3', 'v3'], 'tried, switched, then kept');
});

test('Test connection reads the location, their objects, products and pipelines, and never writes', async () => {
  const s = fakeState();
  const t = await testConnection(ghlFor(s));
  assert.equal(t.ok, true);
  assert.equal(t.target, 'custom_object');
  assert.equal(t.test.location!.name, '01 Motors (test CRM)');
  assert.deepEqual(t.test.objects.map((o) => o.key), ['custom_objects.vehicles']);
  assert.equal(t.test.pipelines[0]!.stages.length, 2);
  assert.ok(s.log.every((l) => l.method === 'GET'), 'reads only');
  const wrong = await testConnection(createGhl({ token: TOKEN, locationId: 'someoneElse01', fetch: fakeGhlFetch(s), sleep: noSleep }));
  assert.equal(wrong.ok, false);
  assert.match(wrong.error!, /not allowed|location/i);
  const noObj = await testConnection(ghlFor(s, 'pit-noobjects-1234-abcd-ef00'));
  assert.equal(noObj.target, 'products');
});

test('their cars come in from the object that holds them: names, rates, photos and booked dates normalised', async () => {
  const s = fakeState();
  const r = await runSync(job({ cars: [], connection: conn({ share_cars: false, inbound_object_key: 'vehicles' }) }), deps(ghlFor(s)));
  assert.equal(r.ok, true, r.error ?? '');
  assert.equal(r.inbound!.length, 2);
  const g = r.inbound!.find((x) => x.remote_id === 'rec-g63')!;
  assert.deepEqual([g.make, g.model, g.trim, g.base_cents, g.photos.length], ['Mercedes-Benz', 'G-Class', 'G63 AMG', 110000, 2]);
  assert.deepEqual(g.booked, [{ from: '2026-11-20', to: '2026-11-22' }]);
  const n = r.inbound!.find((x) => x.remote_id === 'rec-new')!;
  assert.deepEqual([n.year, n.make, n.model, n.base_cents, n.seats], [2025, 'Mercedes-Benz', 'CLE', 45000, 4]);
  // our own object is never read as theirs
  const loop = await runSync(job({ cars: [], connection: conn({ share_cars: false, inbound_object_key: 'carmacars_vehicles' }) }), deps(ghlFor(s)));
  assert.equal(loop.inbound, null);
  assert.match(loop.error!, /cannot come from the object we fill/);
  // a failed read is "not read", never "they have no cars" (which would mark every car gone)
  const failed = await runSync(job({ cars: [], connection: conn({ share_cars: false, inbound_object_key: 'vehicles' }) }), deps(ghlFor(s, 'pit-noobjects-1234-abcd-ef00')));
  assert.equal(failed.inbound, null);
});

test('their cars from products skip the products we made; from a feed, JSON or CSV', async () => {
  const s = fakeState();
  const out = await runSync(job({ connection: conn({ outbound_target: 'products' }) }), deps(ghlFor(s)));
  s.products.set('theirs1', { _id: 'theirs1', name: '2024 Porsche Macan S', image: 'https://images.example.test/macan.jpg' });
  s.prices.set('theirs1', [{ _id: 'pr1', name: 'Daily', amount: 250, currency: 'CAD', type: 'one_time' }]);
  const r = await runSync(job({ cars: [], records: out.records, connection: conn({ share_cars: false, inbound_source: 'products' }) }), deps(ghlFor(s)));
  assert.deepEqual(r.inbound!.map((x) => [x.remote_id, x.make, x.model, x.base_cents]), [['theirs1', 'Porsche', 'Macan', 25000]]);
  const feed = await runSync(job({ cars: [], connection: conn({ share_cars: false, inbound_feed_url: 'https://01motors.example.test/feed.csv' }) }),
    { ...deps(ghlFor(s)), fetchFeed: async () => 'id,name,daily_rate,photos\nX1,"2025 BMW M4 Competition","$475","https://images.example.test/m4.jpg"\n' });
  assert.deepEqual(feed.inbound!.map((x) => [x.remote_kind, x.remote_id, x.make, x.model, x.base_cents, x.photos[0]]), [['feed', 'X1', 'BMW', 'M4', 47500, 'https://images.example.test/m4.jpg']]);
  const j = fromFeed(JSON.stringify({ vehicles: [{ id: 7, make: 'Audi', model: 'R8', rate_per_day: 1000, unavailable: [{ start: '2026-12-01', end: '2026-12-02' }] }] }));
  assert.deepEqual([j[0]!.remote_id, j[0]!.make, j[0]!.base_cents, j[0]!.booked.length], ['7', 'Audi', 100000, 1]);
});

test('leads (when on): a request becomes a contact and an opportunity in their pipeline; their stage becomes leads here', async () => {
  const s = fakeState();
  const c = conn({ share_cars: false, leads_enabled: true, pipeline_id: 'pipeRentals01', pipeline_stage_id: 'stageNew01', inbound_stage_id: 'stageSendCC' });
  const r = await runSync(job({ cars: [], connection: c, leads: [
    { booking_id: 'b1', booking_number: 'CC-1001', reason: 'referral', status: 'requested', name: 'Rita Example', email: 'rita@example.test', phone: null, car: '2024 BMW X5', pickup_at: '2026-11-01T14:00:00Z', return_at: '2026-11-03T14:00:00Z', total_cents: 56700 },
    { booking_id: 'b2', booking_number: 'CC-1002', reason: 'partner_car', status: 'requested', name: 'No Contact', email: null, phone: null, car: 'Their G63', pickup_at: '2026-11-01T14:00:00Z', return_at: '2026-11-03T14:00:00Z', total_cents: null }
  ] }), deps(ghlFor(s)));
  assert.equal(r.ok, true, r.error ?? '');
  assert.equal(r.counts.leads_sent, 1);
  assert.deepEqual(r.leads.map((l) => [l.booking_id, l.ok, !!l.skipped]), [['b1', true, false], ['b2', false, true]]);
  const opp = s.opportunities.find((o) => o.name.includes('CC-1001'))!;
  assert.deepEqual([opp.pipelineStageId, opp.monetaryValue, opp.source], ['stageNew01', 567, 'CarmaCars (your booking link)']);
  assert.deepEqual([...s.contacts.values()][0]!.tags, ['carmacars', 'carmacars-referral']);
  assert.deepEqual(r.partner_leads.map((l) => [l.opportunity_id, l.email]), [['oppFromPartner1', 'sam.example@example.test']]);
  const again = await runSync(job({ cars: [], connection: c, known_opportunities: ['oppFromPartner1'] }), deps(ghlFor(s)));
  assert.equal(again.partner_leads.length, 0);
  // off: nothing is sent or read
  const off = await runSync(job({ cars: [], connection: conn({ share_cars: false }), leads: [{ booking_id: 'b3', booking_number: 'CC-1003', reason: 'referral', status: 'requested', name: 'X', email: 'x@example.test', phone: null, car: 'Car', pickup_at: '', return_at: '', total_cents: 1 }] }), deps(ghlFor(s)));
  assert.equal(off.leads.length, 0);
});

test('mapping: names, money, booked dates, photo addresses, the feed CSV (no formulas), the hash', () => {
  assert.deepEqual(parseName('2025 Mercedes C43 AMG White'), { year: 2025, make: 'Mercedes-Benz', model: 'C43', trim: 'AMG White' });
  assert.deepEqual(parseName('Range Rover Sport V8'), { year: null, make: 'Land Rover', model: 'Range Rover Sport', trim: 'V8' });
  assert.deepEqual(parseName('Something odd'), { year: null, make: null, model: null, trim: null });
  assert.deepEqual([toCents('$1,250.50'), toCents(99), toCents({ currency: 'CAD', value: 10 }), toCents(''), toCents('free')], [125050, 9900, 1000, null, null]);
  assert.deepEqual(bookedRuns('2026-11-01 to 2026-11-03; 2026-11-10'), [{ from: '2026-11-01', to: '2026-11-03' }, { from: '2026-11-10', to: '2026-11-10' }]);
  assert.deepEqual(photoUrls(['a/b.jpg', '/s.svg', 'https://x.example.test/c.jpg'], 'https://carmacars.ca/', (p) => `https://cdn.example.test/${p}`),
    ['https://cdn.example.test/a/b.jpg', 'https://carmacars.ca/s.svg', 'https://x.example.test/c.jpg']);
  const csv = feedCsv([feedRow(car('a', { name: '=HYPERLINK("x")' }), ['https://p.example.test/1.jpg'])]);
  assert.match(csv, /^car_code,name,year,/);
  assert.match(csv, /"'=HYPERLINK\(""x""\)"/);
  const props = recordProperties(car('a', { availability: null, daily_cents: null }), []);
  assert.ok(!('daily_rate' in props) && !('next_free_date' in props), 'unknown numbers and dates are left out');
  assert.equal(payloadHash({ a: 1, b: [2, 3] }), payloadHash({ b: [2, 3], a: 1 }));
  assert.notEqual(payloadHash({ a: 1 }), payloadHash({ a: 2 }));
});

test('the feed key: the same for the same version, a new one after New key, checked in constant time', async () => {
  const k1 = await feedKey('x'.repeat(40), 'partner-1', 1);
  assert.match(k1, /^[0-9a-f]{40}$/);
  assert.equal(k1, await feedKey('x'.repeat(40), 'partner-1', 1));
  assert.notEqual(k1, await feedKey('x'.repeat(40), 'partner-1', 2));
  assert.equal(await feedKeyOk('x'.repeat(40), 'partner-1', 1, k1), true);
  assert.equal(await feedKeyOk('x'.repeat(40), 'partner-1', 2, k1), false);
  assert.equal(await feedKeyOk('x'.repeat(40), 'partner-1', 1, null), false);
});

test('the widget: no script, every value escaped, each card a booking link in a new tab', () => {
  const html = renderWidget([car('a', { name: '<script>alert(1)</script>' })], { title: 'CarmaCars cars', siteName: 'CarmaCars', photos: () => ['https://p.example.test/1.jpg'] });
  assert.ok(!/<script/i.test(html));
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /href="https:\/\/carmacars\.ca\/p\/01-motors\/bmw-x5-a" target="_blank" rel="noopener"/);
  assert.match(html, /\$189<small> a day/);
  assert.match(renderWidget([], { title: 't', siteName: 'CarmaCars', photos: () => [] }), /No cars to show/);
});

test('the client refuses to start without a token or a location', () => {
  assert.throws(() => createGhl({ token: '', locationId: LOC }), GhlError);
  assert.throws(() => createGhl({ token: TOKEN, locationId: 'x' }), GhlError);
});

test('only the widget may be framed, and only by https sites', async () => {
  const { embeddable, cspHeader } = await import('../../lib/security/csp.ts');
  assert.equal(embeddable('/partner-widget/0b0e8f5e-1111-4222-8333-123456789abc'), true);
  for (const p of ['/', '/cars', '/admin/settings/partners', '/partner-feed/0b0e8f5e-1111-4222-8333-123456789abc', '/partner-widget/x', '/partner-widget/0b0e8f5e-1111-4222-8333-123456789abc/more'])
    assert.equal(embeddable(p), false, p);
  assert.match(cspHeader('n'), /frame-ancestors 'none'/);
  assert.match(cspHeader('n', { frameAncestors: 'https:' }), /frame-ancestors https:;/);
});
