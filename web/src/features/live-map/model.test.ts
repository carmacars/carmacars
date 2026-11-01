import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { agoText, arc, bandOf, compactMoney, hash, makeInitial, onTheRoad, photoPins, maskPhone, reasonOf, scoreOf, shortAgo, shortName, signalsOf, spotlight, spread, stageOf, tally, toView, verbOf, type RawMap, type RawPin } from './model.ts';
import { HOME_BOUNDS, MAX_BOUNDS, inBounds, roundGeo } from './config.ts';

// The Live map (migration 0242): the score and its signals, the masking for the TV, the spread of pins that share a spot.
const facts = { pages: 0, seconds: 0, cars: 0, visit: 1, past: 0, game: false, claimed: false, live_score: null, reasons: [] };
const pin = (o: Partial<RawPin> = {}): RawPin => ({
  id: 'a', type: 'session', types: ['session'], at: '2026-11-04T15:00:00Z', detail: null, booking_number: null, renter_id: null, session_id: null,
  name: null, email: null, phone: null, city: 'Mississauga', lat: 43.59, lng: -79.64, precision: 'visit', online: true, device: 'phone', from_ad: false,
  facts, car: null, ...o
});
const raw = (pins: RawPin[]): RawMap => ({ at: '2026-11-04T15:00:00Z', days: 30, cap: 500, live_minutes: 3, kpi: { active_now: 1, requests_today: 0, bookings_week: 0, on_rent_now: 0, collected_month_cents: 0 }, totals: {}, pins, fleet: [] });

describe('score and signals', () => {
  it('adds the points of what the person did, capped at 100, strongest first', () => {
    const s = signalsOf(pin({ type: 'request', facts: { ...facts, pages: 12, seconds: 900, cars: 3, visit: 2, past: 1, claimed: true } }));
    assert.deepEqual(s.map((x) => x.label).slice(0, 3), ['Request sent', 'Claimed a game prize', '12 pages']);
    assert.equal(scoreOf(s), Math.min(100, 35 + 12 + 10 + 10 + 10 + 8 + 8 + 6));
    assert.equal(scoreOf(signalsOf(pin({ type: 'booking', facts: { ...facts, pages: 40, seconds: 4000, cars: 9, visit: 9, past: 5, claimed: true } }))), 100);
  });
  it('takes the Live visitors reasons with their points, never a negative one', () => {
    const s = signalsOf(pin({ online: false, facts: { ...facts, live_score: 40, reasons: [{ label: 'Pickup soon', why: 'Pickup tomorrow', weight: 25 }, { label: 'Price watch', weight: -5 }] } }));
    assert.deepEqual(s, [{ label: 'Pickup tomorrow', points: 25, live: true }]);
  });
  it('bands like Live visitors: hot from 60, warm from 30', () => {
    assert.deepEqual([bandOf(60), bandOf(59), bandOf(30), bandOf(29)], ['hot', 'warm', 'warm', 'cold']);
  });
});

describe('masking', () => {
  it('shows first name and last initial and the last 4 digits; no email; anonymous visitors by city', () => {
    const v = toView(raw([pin({ name: 'maya van chen', email: 'maya@example.test', phone: '(647) 555-0199' }), pin({ id: 'b', city: null })]), false);
    const [m, b] = [v.pins[0]!, v.pins[1]!];
    assert.equal(m.who, 'Maya C.');
    assert.equal(m.email, null);
    assert.equal(m.phone, 'ending 0199');
    assert.equal(b.who, 'Visitor');
    assert.equal(toView(raw([pin()]), false).pins[0]?.who, 'Visitor in Mississauga');
    assert.equal(v.masked, true);
  });
  it('shows everything with details on', () => {
    const p = toView(raw([pin({ name: 'Maya Chen', email: 'maya@example.test', phone: '6475550199' })]), true).pins[0]!;
    assert.deepEqual([p.who, p.email, p.phone], ['Maya Chen', 'maya@example.test', '6475550199']);
  });
  it('helpers', () => {
    assert.equal(shortName('  ana  '), 'Ana');
    assert.equal(shortName(''), null);
    assert.equal(maskPhone('12'), null);
  });
});

describe('positions', () => {
  it('a lone pin stays put; pins on one spot go round it, the same way every time, within about 400 m', () => {
    assert.deepEqual(spread([{ id: 'x', lng: -79.38, lat: 43.65 }]), [{ id: 'x', lng: -79.38, lat: 43.65 }]);
    const pts = ['c', 'a', 'b'].map((id) => ({ id, lng: -79.38, lat: 43.65 }));
    const one = spread(pts), two = spread([...pts].reverse());
    assert.deepEqual(one.map((p) => p.id), ['a', 'b', 'c']);
    assert.deepEqual(one, two);
    for (const p of one) assert.ok(Math.abs(p.lat - 43.65) < 0.004 && Math.abs(p.lng + 79.38) < 0.006);
    assert.equal(new Set(one.map((p) => `${p.lat.toFixed(5)},${p.lng.toFixed(5)}`)).size, 3);
    assert.equal(hash('a'), hash('a'));
  });
  it('counts the pins with no position and the ones outside southern Ontario', () => {
    const v = toView(raw([pin(), pin({ id: 'n', lat: null, lng: null }), pin({ id: 'o', lat: 49.28, lng: -123.12 })]), false);
    const t = tally(v, (lng, lat) => inBounds(lng, lat, MAX_BOUNDS));
    assert.deepEqual([t.shown, t.none, t.outside, t.byType.session], [1, 1, 1, 3]);
  });
  it('the first view takes in Kitchener, St. Catharines, Cobourg, Peterborough and Barrie, with Toronto inside', () => {
    for (const [lng, lat] of [[-80.49, 43.45], [-79.25, 43.16], [-78.17, 43.96], [-78.32, 44.3], [-79.69, 44.39], [-79.38, 43.65]] as const) assert.ok(inBounds(lng, lat, HOME_BOUNDS));
  });
  it('the Worker rounds Cloudflare\'s position to 0.01 degree', () => {
    assert.deepEqual([roundGeo('43.65321'), roundGeo(-79.38712), roundGeo('x'), roundGeo(''), roundGeo(undefined), roundGeo('500')], [43.65, -79.39, null, null, null, null]);
  });
});

describe('spotlight and time', () => {
  it('hottest first, at most n', () => {
    const v = toView(raw([pin({ id: 'cold', online: false }), pin({ id: 'hot', type: 'request' }), pin({ id: 'warm', type: 'lead' })]), false);
    assert.deepEqual(spotlight(v, 2).map((p) => p.id), ['hot', 'warm']);
  });
  it('says how long ago', () => {
    const now = Date.parse('2026-11-04T15:00:00Z');
    assert.deepEqual(['2026-11-04T15:00:20Z', '2026-11-04T14:58:00Z', '2026-11-04T12:00:00Z', '2026-11-03T15:00:00Z', '2026-11-01T15:00:00Z'].map((x) => agoText(x, now)),
      ['now', '2 min ago', '3 h ago', '1 day ago', '3 days ago']);
  });
});

describe('the wall', () => {
  it('four stages, four colours, with counts', () => {
    assert.deepEqual(['on_rent', 'booking', 'request', 'lead', 'draft', 'game', 'session', 'previous'].map((t) => stageOf(t as never)),
      ['booked', 'booked', 'progress', 'progress', 'progress', 'site', 'site', 'past']);
    const v = toView(raw([pin(), pin({ id: 'r', type: 'request' }), pin({ id: 'b', type: 'booking' })]), false);
    const t = tally(v, () => true);
    assert.deepEqual([t.byStage.booked, t.byStage.progress, t.byStage.site, t.byStage.past], [1, 1, 1, 0]);
  });
  it('one reason line: the two strongest signals after the stage itself', () => {
    const p = toView(raw([pin({ type: 'request', facts: { ...facts, pages: 12, reasons: [{ label: 'Pickup soon', why: 'Pickup tomorrow', weight: 25 }] } })]), false).pins[0]!;
    assert.equal(reasonOf(p.signals), 'Pickup tomorrow · 12 pages');
  });
  it('the feed says what happened', () => {
    assert.equal(verbOf({ type: 'draft', detail: 'Started the booking request (dates)' }), 'started a booking');
    assert.equal(verbOf({ type: 'game', detail: null, signals: [{ label: 'Claimed a game prize', points: 12 }] }), 'won a discount');
    assert.equal(verbOf({ type: 'session', detail: null }), 'is on the site');
  });
  it('money and time read across the room', () => {
    assert.deepEqual([compactMoney(4823500), compactMoney(123456789), compactMoney(95000), compactMoney(-250000)], ['$48.2K', '$1.2M', '$950', '-$2.5K']);
    const now = Date.parse('2026-11-04T15:00:00Z');
    assert.deepEqual(['2026-11-04T14:59:50Z', '2026-11-04T14:58:00Z', '2026-11-04T12:00:00Z', '2026-11-02T15:00:00Z'].map((x) => shortAgo(x, now)), ['now', '2m', '3h', '2d']);
  });
});

describe('photo pins, the road and the arcs', () => {
  it('on rent, booked and hot leads with a car get a photo pin, at most 60', () => {
    const car = { id: 'c', code: null, name: '2024 Toyota Corolla', daily_cents: 6900, photo: null, how: 'viewed' };
    const v = toView(raw([pin({ id: 'r', type: 'on_rent', car }), pin({ id: 'b', type: 'booking', car }), pin({ id: 'n', type: 'booking' }), pin({ id: 's', car })]), false);
    assert.deepEqual([...photoPins(v.pins)].sort(), ['b', 'r']);
    assert.equal(photoPins(v.pins, 1).size, 1);
    assert.deepEqual([makeInitial('2024 Toyota Corolla'), makeInitial(''), makeInitial(null)], ['T', '?', '?']);
  });
  it('on the road: on rent now, and bookings picked up today', () => {
    const now = Date.parse('2026-11-04T15:00:00Z');
    const v = toView(raw([pin({ id: 'r', type: 'on_rent', return_at: '2026-11-06T15:00:00Z' }), pin({ id: 't', type: 'booking', pickup_at: '2026-11-04T20:00:00Z' }),
      pin({ id: 'l', type: 'booking', pickup_at: '2026-11-09T20:00:00Z' })]), false);
    assert.deepEqual(onTheRoad(v.pins, now).map((p) => p.id), ['r', 't']);
  });
  it('an arc runs from one end to the other, bowed', () => {
    const a = arc([-79.4, 43.7], [-79.0, 43.9]);
    assert.deepEqual([a[0], a[a.length - 1]], [[-79.4, 43.7], [-79.0, 43.9]]);
    const mid = a[Math.floor(a.length / 2)]!;
    assert.ok(Math.abs(mid[1] - 43.8) > 0.01);
  });
});
