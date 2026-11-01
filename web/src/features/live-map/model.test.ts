import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { CAR_SILHOUETTE, agoText, arc, separate, bandOf, carLabel, compactMoney, hash, makeInitial, onTheRoad, photoPins, reasonOf, adminHref, isLead, timeLine, withoutContact, mx, my, scoreOf, shortAgo, shortName, signalsOf, spotlight, spread, stageOf, tally, toView, verbOf, type RawMap, type RawPin } from './model.ts';
import { FRAME_MAX_ZOOM, TORONTO, HIGHWAYS, HOME_BOUNDS, MAP_ATTRIBUTION, MAX_BOUNDS, REGIONS, frameBounds, inBounds, roundGeo } from './config.ts';
import { readFileSync } from 'node:fs';

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

describe('names and contact (Release 26)', () => {
  it('names always: first name and last initial on pins, the full name for the card, anonymous visitors by city', () => {
    const v = toView(raw([pin({ name: 'maya  van chen', email: 'maya@example.test', phone: '(647) 555-0199' }), pin({ id: 'b', city: null })]), false);
    const [m, b] = [v.pins[0]!, v.pins[1]!];
    assert.equal(m.who, 'Maya C.');
    assert.equal(m.name, 'maya van chen');
    assert.equal(b.who, 'Visitor');
    assert.equal(b.name, null);
    assert.equal(toView(raw([pin()]), false).pins[0]?.who, 'Visitor in Mississauga');
  });
  it('without Show contact no phone or email is in the answer, not even the last digits', () => {
    const v = toView(raw([pin({ name: 'Maya Chen', email: 'maya@example.test', phone: '6475550199' })]), false);
    assert.equal(v.contact, false);
    assert.deepEqual([v.pins[0]!.email, v.pins[0]!.phone], [null, null]);
    const json = JSON.stringify(v);
    assert.doesNotMatch(json, /example\.test|0199|555/);
  });
  it('with Show contact: the phone and email; and they leave at once when it is turned off', () => {
    const v = toView(raw([pin({ name: 'Maya Chen', email: 'maya@example.test', phone: '6475550199' })]), true);
    assert.deepEqual([v.contact, v.pins[0]!.email, v.pins[0]!.phone], [true, 'maya@example.test', '6475550199']);
    const off = withoutContact(v);
    assert.equal(off.contact, false);
    assert.doesNotMatch(JSON.stringify(off), /example\.test|0199/);
  });
  it('helpers', () => {
    assert.equal(shortName('  ana  '), 'Ana');
    assert.equal(shortName(''), null);
  });
  it('the card links into Admin: the booking, else the renter, else Live visitors, else Renter leads', () => {
    const base = { booking_number: null, renter_id: null, session_id: null, name: null, type: 'lead' as const };
    assert.deepEqual(adminHref({ ...base, booking_number: 'CC-1042' }), { href: '/admin/bookings/CC-1042', label: 'Open booking CC-1042' });
    assert.equal(adminHref({ ...base, renter_id: 'r1' }).href, '/admin/renters/r1');
    assert.equal(adminHref({ ...base, type: 'session', session_id: 's1' }).href, '/admin/visitors');
    assert.equal(adminHref({ ...base, name: 'Erin Example' }).href, '/admin/leads?q=Erin%20Example');
  });
  it('the card\'s time line', () => {
    const now = Date.parse('2026-11-06T12:00:00Z');
    assert.equal(timeLine({ online: true, at: '2026-11-06T11:59:00Z', seconds: 720 }, now), 'On the site now, 12 min on the site');
    assert.equal(timeLine({ online: false, at: '2026-11-06T09:00:00Z', seconds: null }, now), 'last seen 3h ago');
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
  it('the view (the owner\'s box, Release 26): Hamilton, Barrie and Toronto inside; St. Catharines, across the lake, not', () => {
    for (const [lng, lat] of [[-79.87, 43.256], [-79.69, 44.389], [-79.38, 43.65], [-78.9, 43.9]] as const) assert.ok(inBounds(lng, lat, HOME_BOUNDS));
    assert.ok(!inBounds(-79.25, 43.16, HOME_BOUNDS), 'St. Catharines is across the lake, out of the view');
  });
  it('the Worker rounds Cloudflare\'s position to 0.01 degree', () => {
    assert.deepEqual([roundGeo('43.65321'), roundGeo(-79.38712), roundGeo('x'), roundGeo(''), roundGeo(undefined), roundGeo('500')], [43.65, -79.39, null, null, null, null]);
  });
});

describe('spotlight and time', () => {
  it('a renter is never the hottest lead: not on rent, not booked, not paying for an accepted offer, whatever the score', () => {
    const v = toView(raw([
      pin({ id: 'rent', type: 'on_rent', types: ['on_rent'], online: true, facts: { pages: 40, seconds: 3600, cars: 9, visit: 9, past: 3, game: true, claimed: true, live_score: 100, reasons: [] } }),
      pin({ id: 'booked', type: 'booking', types: ['booking'], online: true }),
      pin({ id: 'mix', type: 'game', types: ['game', 'on_rent'], online: true }),
      pin({ id: 'paying', type: 'request', types: ['request'], detail: 'Awaiting payment, pickup Nov 9', online: true }),
      pin({ id: 'game', type: 'game', types: ['game'], online: false })]), false);
    assert.ok(v.pins.find((p) => p.id === 'rent')!.score > v.pins.find((p) => p.id === 'game')!.score, 'the renter scores higher');
    assert.deepEqual(spotlight(v).map((p) => p.id), ['game']);
    assert.equal(isLead(v.pins.find((p) => p.id === 'rent')!), false);
    assert.equal(isLead({ type: 'previous', types: ['previous', 'session'], detail: null }), true, 'a past renter back browsing is a lead');
    assert.equal(isLead({ type: 'request', types: ['request'], detail: 'Offer sent, pickup Nov 9' }), true);
  });
  it('no lead at all: an empty spotlight, never a renter in its place', () => {
    const v = toView(raw([pin({ id: 'rent', type: 'on_rent', types: ['on_rent'] }), pin({ id: 'booked', type: 'booking', types: ['booking'] })]), false);
    assert.deepEqual(spotlight(v), []);
  });
  it('a hot renter gets no "hot lead" photo pin of its own; a hot lead does', () => {
    const v = toView(raw([pin({ id: 'req', type: 'request', types: ['request', 'booking'], online: true, facts: { pages: 40, seconds: 3600, cars: 9, visit: 9, past: 0, game: true, claimed: true, live_score: 100, reasons: [] }, car: { id: 'c', code: null, name: 'Car', daily_cents: null, photo: null, how: 'viewed' } })]), false);
    assert.equal(v.pins[0]!.band, 'hot');
    assert.equal(photoPins(v.pins).has('req'), false);
  });
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

// Release 25: a booking with no car yet gets a proper card, never "Car ?"; the GTA's highways are the site's own file.
describe('car label (On the road, photo pins)', () => {
  it('a booking with no car: "Car not assigned", the neutral car', () => {
    assert.deepEqual(carLabel(null), { name: 'Car not assigned', assigned: false, initial: null });
    assert.deepEqual(carLabel(undefined), { name: 'Car not assigned', assigned: false, initial: null });
  });
  it('a car: its name and the make\'s initial', () => {
    assert.deepEqual(carLabel({ name: '2024 Toyota Corolla', code: 'CC-7F3A' }), { name: '2024 Toyota Corolla', assigned: true, initial: 'T' });
  });
  it('a car with no name: its code, and the neutral car instead of a question mark', () => {
    assert.deepEqual(carLabel({ name: '', code: 'CC-7F3A' }), { name: 'Car CC-7F3A', assigned: true, initial: null });
    assert.deepEqual(carLabel({ name: '  ', code: null }), { name: 'Car', assigned: true, initial: null });
  });
  it('the neutral car is a plain inline drawing in the card\'s colour', () => {
    assert.match(CAR_SILHOUETTE, /^<svg [^>]*fill="currentColor"/);
    assert.doesNotMatch(CAR_SILHOUETTE, /https?:\/\/|<script|on\w+=/);
  });
});

describe('GTA highways (web/public/live-map/highways.geojson)', () => {
  type Line = { properties: { ref: string; kind: string }; geometry: { type: string; coordinates: number[][] } };
  const d = JSON.parse(readFileSync(new URL(`../../../public${HIGHWAYS}`, import.meta.url), 'utf8')) as { attribution: string; features: Line[] };
  it('the seven asked for, and the 400, 403 and 407 so the area keeps them', () => {
    assert.deepEqual(d.features.map((f) => f.properties.ref).sort(), ['400', '401', '403', '404', '407', '410', '427', 'DVP', 'Gardiner', 'QEW']);
  });
  it('lines inside southern Ontario, a few points each, saying who drew them', () => {
    for (const f of d.features) {
      assert.equal(f.geometry.type, 'LineString');
      assert.ok(f.geometry.coordinates.length >= 5 && f.geometry.coordinates.length <= 80, f.properties.ref);
      for (const [x, y] of f.geometry.coordinates) assert.ok(inBounds(x!, y!, MAX_BOUNDS), `${f.properties.ref} ${x},${y}`);
    }
    assert.match(d.attribution, /CarmaCars/);
    assert.match(MAP_ATTRIBUTION, /Natural Earth/);
    assert.match(MAP_ATTRIBUTION, /CarmaCars/);
  });
  it('the 401 runs west to east across the GTA, north of the lake at Yonge Street', () => {
    const c = d.features.find((f) => f.properties.ref === '401')!.geometry.coordinates;
    for (let i = 1; i < c.length; i++) assert.ok(c[i]![0]! > c[i - 1]![0]!, 'eastward');
    const atYonge = c.find(([x]) => Math.abs(x! - -79.406) < 0.01)!;
    assert.ok(atYonge[1]! > 43.73 && atYonge[1]! < 43.76);
  });
  it('the basemap draws no Natural Earth road inside the GTA, so no highway is drawn twice', () => {
    const base = JSON.parse(readFileSync(new URL('../../../public/live-map/basemap.geojson', import.meta.url), 'utf8')) as { features: Array<{ properties: { k: string }; geometry: { coordinates: number[][][] } }> };
    for (const f of base.features.filter((x) => x.properties.k === 'road')) for (const l of f.geometry.coordinates) for (const [x, y] of l) {
      assert.ok(!(x! > -79.95 && x! < -78.75 && y! > 43.33 && y! < 44.12), `${x},${y}`);
    }
  });
});

describe('Release 26: the land, not the lake', () => {
  it('Hamilton is the furthest south, Barrie the furthest north, Toronto in the middle', () => {
    const [w, south, e, n] = HOME_BOUNDS;
    assert.ok(south > 43.2 && south <= 43.256, `Hamilton (43.256) at the bottom: ${south}`);
    assert.ok(n >= 44.389 && n < 44.45, `Barrie (44.389) at the top: ${n}`);
    assert.ok(Math.abs((w + e) / 2 - TORONTO[0]) < 0.01, 'centred on Toronto east to west');
  });
  it('widens only for a pin outside the box, and stays centred on Toronto; never closer than a city', () => {
    assert.deepEqual(frameBounds([]), HOME_BOUNDS);
    assert.deepEqual(frameBounds([{ lng: -79.38, lat: 43.65 }]), HOME_BOUNDS, 'a pin inside changes nothing');
    const far = frameBounds([{ lng: -80.49, lat: 43.45 }, { lng: Number.NaN, lat: 43 }]);
    assert.ok(Math.abs(far[0] - -80.49) < 1e-9);
    assert.ok(Math.abs((far[0] + far[2]) / 2 - TORONTO[0]) < 1e-9, 'Kitchener widens both sides, Toronto stays in the middle');
    assert.deepEqual([far[1], far[3]], [HOME_BOUNDS[1], HOME_BOUNDS[3]]);
    assert.ok(FRAME_MAX_ZOOM >= 9 && FRAME_MAX_ZOOM <= 10.5);
  });
});

describe('Release 26: photo pins make room for each other (separate)', () => {
  const overlap = (a: { x: number; y: number }, b: { x: number; y: number }, w: number, h: number) => Math.abs(a.x - b.x) < w && Math.abs(a.y - b.y) < h;
  it('a lone pin stays on its spot', () => {
    assert.deepEqual(separate([{ id: 'a', x: 100, y: 100, w: 80, h: 54 }]).get('a'), { x: 100, y: 100 });
  });
  it('five cars on one spot by home base: a tidy block, none covering another or home base, which never moves', () => {
    const boxes = [...'abcde'].map((id) => ({ id, x: 500, y: 300, w: 80, h: 54 }));
    const at = separate([...boxes, { id: 'hq', x: 505, y: 302, w: 30, h: 30, fixed: true }], 8);
    assert.deepEqual(at.get('hq'), { x: 505, y: 302 });
    const ids = [...'abcde'];
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) assert.ok(!overlap(at.get(ids[i]!)!, at.get(ids[j]!)!, 80, 54), `${ids[i]} ${ids[j]}`);
      assert.ok(!overlap(at.get(ids[i]!)!, at.get('hq')!, 55, 42), `${ids[i]} hq`);
      // and they stay near their spot (a leader line, not across the map)
      assert.ok(Math.hypot(at.get(ids[i]!)!.x - 500, at.get(ids[i]!)!.y - 300) < 260);
    }
  });
  it('the same answer every refresh, whatever order the pins come in', () => {
    const a = [{ id: 'x', x: 10, y: 10, w: 80, h: 54 }, { id: 'y', x: 20, y: 12, w: 80, h: 54 }, { id: 'z', x: 15, y: 30, w: 80, h: 54 }];
    assert.deepEqual([...separate(a)].sort(), [...separate([...a].reverse())].sort());
  });
});

describe('Release 26: the GTA\'s regions (web/public/live-map/regions.geojson)', () => {
  type F = { properties: { k: string; region?: string; lvl?: string; name?: string; w?: number }; geometry: { type: string; coordinates: unknown } };
  const raw = readFileSync(new URL(`../../../public${REGIONS}`, import.meta.url), 'utf8');
  const d = JSON.parse(raw) as { attribution: string; features: F[] };
  it('small, and says where it comes from (ODbL)', () => {
    assert.ok(raw.length < 120_000, `${raw.length} bytes`);
    assert.match(d.attribution, /Statistics Canada/);
    assert.match(d.attribution, /ODbL/);
    assert.match(MAP_ATTRIBUTION, /Statistics Canada/);
  });
  it('the five regions and Hamilton, with the big cities in the right one', () => {
    const munis = d.features.filter((f) => f.properties.k === 'muni');
    assert.deepEqual([...new Set(munis.map((f) => f.properties.region))].sort(), ['Durham', 'Halton', 'Hamilton', 'Peel', 'Toronto', 'York']);
    const regionOf = (n: string) => munis.find((f) => f.properties.name === n)?.properties.region;
    assert.equal(regionOf('Mississauga'), 'Peel');
    assert.equal(regionOf('Markham'), 'York');
    assert.equal(regionOf('Oshawa'), 'Durham');
    assert.equal(regionOf('Oakville'), 'Halton');
  });
  it('every municipality outlined, the GTA\'s regions marked, lines inside southern Ontario', () => {
    const borders = d.features.filter((f) => f.properties.k === 'border');
    assert.deepEqual(borders.map((f) => f.properties.lvl).sort(), ['muni', 'region']);
    for (const f of borders) for (const l of f.geometry.coordinates as number[][][]) for (const [x, y] of l) assert.ok(inBounds(x!, y!, MAX_BOUNDS), `${x},${y}`);
    // Barrie (outside the GTA) is outlined too: a border passes within 6 km of it
    const near = borders.some((f) => (f.geometry.coordinates as number[][][]).some((l) => l.some(([x, y]) => Math.hypot(x! + 79.69, y! - 44.389) < 0.06)));
    assert.ok(near, 'Barrie outlined');
  });
  it('the arterials and the owner\'s cities are there, the roads inside the view', () => {
    const arts = d.features.filter((f) => f.properties.k === 'arterial');
    assert.ok(arts.length >= 20);
    for (const n of ['Yonge Street', 'Eglinton Avenue', 'Steeles Avenue', 'Hurontario Street', 'Highway 7']) assert.ok(arts.some((f) => f.properties.name === n), n);
    for (const f of arts) for (const [x, y] of f.geometry.coordinates as number[][]) assert.ok(inBounds(x!, y!, MAX_BOUNDS));
    const towns = d.features.filter((f) => f.properties.k === 'town').map((f) => f.properties.name);
    for (const n of ['Richmond Hill', 'Burlington', 'Pickering', 'Ajax', 'Whitby', 'Milton', 'Newmarket', 'Aurora']) assert.ok(towns.includes(n), n);
  });
  it('the glow is brightest in Toronto, and the two ridges are there', () => {
    const glow = d.features.filter((f) => f.properties.k === 'glow');
    assert.ok(glow.every((f) => f.properties.w! > 0 && f.properties.w! <= 1));
    assert.equal(Math.max(...glow.map((f) => f.properties.w!)), 1);
    assert.deepEqual(d.features.filter((f) => f.properties.k === 'ridge').map((f) => f.properties.name).sort(), ['Niagara Escarpment', 'Oak Ridges Moraine']);
  });
});

describe('Release 26: the Canvas map projects as MapLibre does (Web Mercator, 512 px world)', () => {
  it('the edges and the middle', () => {
    assert.equal(mx(-180), 0); assert.equal(mx(180), 1); assert.equal(mx(0), 0.5);
    assert.ok(Math.abs(my(0) - 0.5) < 1e-12);
    assert.ok(my(43.65) < 0.5 && my(44.39) < my(43.26), 'north is up');
  });
});
