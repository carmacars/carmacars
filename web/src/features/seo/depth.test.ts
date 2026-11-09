// The depth sections (release 35, part M): longer pages from each page's own data, nothing generic.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildDepth, costPer100, depthWordCount, parseL100, type DepthCar, type DepthFacts, type DepthInput } from './depth.ts';
import { withEpoch } from './lastmod.ts';
import { hubCopy } from '../places/copy.ts';
import { writeKit } from '../kit/index.ts';
import { hubKit } from '../kit/pages.ts';
import { TOKENS } from '../kit/fixtures.ts';
import type { Hub } from '../places/data.ts';

const FACTS: DepthFacts = {
  brand: 'CarmaCars', minAge: 18, youngBands: [{ from: 18, to: 20, feeCents: 3500 }, { from: 21, to: 24, feeCents: 2500 }], licenceClasses: ['G2', 'G'], otherLicenceReview: true,
  depositTiersCents: [25000, 50000, 100000], tollFeeCents: 1500, additionalDriverBps: 2500, deductibleCents: 250000, hstBps: 1300, maxDays: 30, weekFrom: 5,
  coverOptions: ['OPCF 27 on your own policy', 'a credit card that covers rentals', 'the CarmaCars Protection Plan'], airports: ['Toronto Pearson', 'Billy Bishop'],
  fuel: { gasCents: 155, premiumExtraCents: 20, kwhCents: 15 }
};
const car = (name: string, daily: number, extra: Partial<DepthCar> = {}): DepthCar => ({ name, path: `/cars/${name.toLowerCase().replace(/\W+/g, '-')}`, dailyCents: daily, weeklyCents: daily * 6,
  monthlyCents: daily * 22, depositCents: 50000, kmPerDay: 200, seats: 5, transmission: 'Automatic', fuel: 'gasoline', className: 'standard', ...extra });
const CARS = [car('2024 Toyota Corolla', 4900), car('2023 Honda CR-V', 6900), car('2022 Mercedes-Benz C300', 11900), car('2021 Kia Carnival', 8900, { seats: 8 })];
const PLACE = { name: 'Mississauga', label: 'Mississauga', kind: 'city', region: 'CA-ON', km: 24.6, originLabel: 'our location', inReach: true, reachKm: 80, deliveryFromCents: 9500,
  airport: { name: 'Toronto Pearson International Airport', iata: 'YYZ', km: 9 }, nearby: [{ name: 'Brampton', path: '/car-rental/brampton-on', km: 18 }] };
const POIS = [
  { kind: 'go_station' as const, agency: 'GO Transit', name: 'Cooksville GO', km: 1.2, source: 'gtfs' as const, attribution: 'Stops: GO Transit GTFS (Metrolinx Open Data Licence)' },
  { kind: 'bus_stop' as const, agency: 'MiWay', name: 'Hurontario St at Dundas St', km: 0.4, source: 'gtfs' as const, attribution: 'Stops: MiWay GTFS (City of Mississauga Open Data Licence)' },
  { kind: 'hotel' as const, agency: null, name: 'Example Hotel Square One', km: 2.1, source: 'osm' as const, attribution: 'Hotels: © OpenStreetMap contributors (ODbL)' }
];
const full: DepthInput = { path: '/car-rental/mississauga-on', facts: FACTS, cars: CARS, place: PLACE, pois: POIS,
  related: { places: [{ href: '/car-rental/brampton-on', label: 'Car rental in Brampton' }], cars: CARS.map((c) => ({ href: c.path, label: c.name })), guides: [{ href: '/guides/407-etr', label: 'The 407 ETR' }] } };

test('a place page gets cars and prices, local logistics, requirements and related links, in that order', () => {
  const d = buildDepth(full);
  assert.deepEqual(d.sections.map((s) => s.id), ['cars', 'logistics', 'requirements', 'related']);
  const all = d.sections.flatMap((s) => s.paras).join(' ');
  assert.match(all, /4 cars match this page/);
  assert.match(all, /\$49 \(2024 Toyota Corolla\) to \$119 \(2022 Mercedes-Benz C300\)/);
  assert.match(all, /Delivery to Mississauga starts at \$95 each way/);
  assert.match(all, /about 25 km in a straight line from our location, roughly \d+ minutes/);
  assert.match(all, /nearest GO station is Cooksville GO, about 1\.2 km/);
  assert.match(all, /Highway 407 ETR has no toll booths/);
  assert.match(all, /\$15 for each toll invoice/);
  assert.match(all, /On-street parking is limited to 5 hours/);
  assert.match(all, /Ontario G2 and G licence/);
  assert.match(all, /18 to 20, \$35 a day and 21 to 24, \$25 a day; from 25 there is none/);
  assert.equal(d.sections[0]!.table!.rows.length, 4);
});

test('every number on the page comes from the input (no invented figure)', () => {
  const d = buildDepth(full);
  const text = JSON.stringify({ s: d.sections, f: d.faq });
  const allowed = new Set(['49', '69', '119', '89', '294', '414', '714', '534', '1,078', '1,518', '2,618', '1,958', '500', '200', '5', '8', '95', '25', '9', '1.2', '0.4', '2.1', '18', '20', '21', '24', '25',
    '35', '15', '30', '250', '1,000', '2,500', '13', '407', '2024', '2023', '2022', '2021', '100', '300', '27', '401', '403', '410', '427', '10', '1', '2', '3', '4', '22', '6', '0']);
  const mins = String(Math.max(10, Math.round(((24.6 * 1.35) / 48) * 60 / 5) * 5));
  allowed.add(mins);
  for (const m of text.matchAll(/\d[\d,]*(?:\.\d+)?/g)) assert.ok(allowed.has(m[0].replace(/,$/, '')), `unexpected number ${m[0]} in ${text.slice(Math.max(0, m.index! - 60), m.index! + 20)}`);
});

test('a page with no matching car lists the nearest similar cars instead, and says so', () => {
  const d = buildDepth({ ...full, cars: [], fallbackCars: CARS });
  const cars = d.sections.find((s) => s.id === 'cars')!;
  assert.match(cars.paras[0]!, /No car matches this page exactly right now\. The nearest similar cars on CarmaCars start at \$49 a day \(2024 Toyota Corolla\)/);
  assert.match(cars.paras[0]!, /brought to Mississauga, about \d+ minutes by road/);
});

test('sample cars never set a price; a fact that is missing leaves its sentence out', () => {
  const d = buildDepth({ path: '/car-rental/x', facts: { ...FACTS, tollFeeCents: null, fuel: null }, cars: [car('2020 Sample Car', 1000, { isSample: true })],
    place: { ...PLACE, name: 'Kingston', label: 'Kingston', km: 240, inReach: false, airport: null } });
  const all = d.sections.flatMap((s) => s.paras).join(' ');
  assert.doesNotMatch(all, /\$10 a day/);
  assert.doesNotMatch(all, /GO station|Highway|parking|toll/i);
  assert.match(all, /beyond the 80 km CarmaCars delivers to/);
});

test('car pages: the figures from vehicle_specs with their sources, the cost to drive 100 km, colours and features by trim', () => {
  const src = 'https://www.fueleconomy.gov/feg/x';
  const specs = [['fuel_city_l100', '7.6'], ['fuel_highway_l100', '5.9'], ['fuel_combined_l100', '6.8'], ['hp', '169'], ['tire_size', '225/45R17'], ['seats', '5'], ['cargo_l', '371']]
    .map(([field, value]) => ({ field: field!, value: value!, source: 'fueleconomy_gov', source_url: src }));
  specs.push({ field: 'paint_colour', value: 'Celestite Grey', code: '1K3', source: 'oem', source_url: 'https://example.test/colours' } as typeof specs[number]);
  specs.push({ field: 'features', value: 'Heated seats', trim: 'SE', source: 'oem', source_url: 'https://example.test/colours' } as typeof specs[number]);
  const d = buildDepth({ path: '/cars/x', facts: FACTS, cars: [], omit: ['requirements'], vehicle: { name: '2024 Toyota Corolla', specs } });
  const sec = d.sections.find((s) => s.id === 'car')!;
  assert.match(sec.paras.join(' '), /rated 7\.6 L\/100 km in the city and 5\.9 on the highway, 6\.8 combined/);
  assert.match(sec.paras.join(' '), /Estimated cost to drive 100 km: \$10\.54 \(6\.8 L\/100 km at \$1\.55 a litre of regular gas/);
  assert.match(sec.paras.join(' '), /Celestite Grey \(1K3\)/);
  assert.match(sec.paras.join(' '), /Key features, SE: Heated seats/);
  assert.ok(sec.table!.rows.some((r) => r[0] === 'Tire size' && r[1] === '225/45R17'));
  assert.ok(!d.sections.some((s) => s.id === 'requirements'));
  assert.ok(d.attributions.includes(`Specs: ${src}`));
  assert.ok(d.faq.some((q) => /How many seats/.test(q.question) && /5, with 371 L/.test(q.answer)));
});

test('car pages without spec data still render the cost from the listing\'s own consumption, and nothing invented', () => {
  assert.equal(parseL100('7.8 L/100 km combined'), 7.8);
  assert.equal(parseL100('about 30 mpg'), null);
  assert.deepEqual(costPer100({ l100: 8, premium: true }, FACTS.fuel), { cents: 1400, basis: '8 L/100 km at $1.75 a litre of premium gas' });
  assert.equal(costPer100({}, FACTS.fuel), null);
  const d = buildDepth({ path: '/cars/x', facts: FACTS, cars: [], vehicle: { name: '2019 Example', specs: [], l100: 8 } });
  const sec = d.sections.find((s) => s.id === 'car')!;
  assert.equal(sec.table, undefined);
  assert.match(sec.paras[0]!, /\$12\.40/);
  const none = buildDepth({ path: '/cars/y', facts: { ...FACTS, fuel: null }, cars: [], vehicle: { name: '2019 Example', specs: [] } });
  assert.ok(!none.sections.some((s) => s.id === 'car' || s.id === 'maintenance'));
});

test('maintenance: shown only from the cost table, with its assumptions and source', () => {
  const d = buildDepth({ path: '/cars/x', facts: FACTS, cars: [], vehicle: { name: '2024 Toyota Corolla', specs: [],
    maintenance: { per_year_cents: 61000, per_10k_km_cents: 38000, assumptions: 'Assumes 16,000 km a year and dealer labour rates in Ontario.', source: 'Example cost table', source_url: 'https://example.test/costs' } } });
  const m = d.sections.find((s) => s.id === 'maintenance')!;
  assert.match(m.paras[0]!, /About \$610 a year, or \$380 per 10,000 km.*Assumes 16,000 km a year/);
  assert.ok(d.attributions.includes('Maintenance costs: https://example.test/costs'));
});

test('comparison pages: our own figures only, the other company named as what was compared, nothing about it', () => {
  const d = buildDepth({ ...full, compare: { company: '01 Motors', versus: true } });
  const c = d.sections.find((s) => s.id === 'compare')!;
  assert.match(c.paras[0]!, /01 Motors is named only because it is what you compared; we do not publish its prices or terms/);
  assert.doesNotMatch(JSON.stringify(c), /cheaper|better than|unlike|not affiliated/i);
  assert.ok(c.table!.rows.some((r) => r[0] === 'Daily rate' && r[1] === 'from $49'));
  assert.ok(d.faq.some((q) => q.question === 'Is this page from 01 Motors?'));
});

test('the questions are written from the facts, ready for FAQPage JSON-LD', () => {
  const d = buildDepth(full);
  assert.ok(d.faq.length >= 6);
  for (const q of d.faq) { assert.ok(q.question.endsWith('?')); assert.ok(q.answer.length > 10); assert.doesNotMatch(q.answer, /\{\{|undefined|NaN/); }
  assert.ok(d.faq.some((q) => /nearest GO station/.test(q.question)));
});

test('sources: OpenStreetMap and the GTFS feeds are attributed when their data is shown, never otherwise', () => {
  const d = buildDepth(full);
  assert.ok(d.attributions.includes('Hotels: © OpenStreetMap contributors (ODbL)'));
  assert.ok(d.attributions.some((a) => a.startsWith('Stops: GO Transit GTFS')));
  const none = buildDepth({ ...full, pois: [] });
  assert.ok(!none.attributions.some((a) => /OpenStreetMap|GTFS/.test(a)));
  assert.ok(!none.sections.flatMap((s) => s.paras).join(' ').includes('Hotels'));
});

test('lastmod: the later of the page\'s date and the content epoch', () => {
  const e = Date.parse('2026-11-08T12:00:00Z');
  assert.equal(withEpoch('2026-10-01T00:00:00Z', e), '2026-11-08T12:00:00.000Z');
  assert.equal(withEpoch('2026-11-09T00:00:00Z', e), '2026-11-09T00:00:00.000Z');
  assert.equal(withEpoch(null, e), '2026-11-08T12:00:00.000Z');
  assert.equal(withEpoch(null, 0), null);
});

// the fee schedule and the cancellation tiers as the fixtures of Program settings and fee types hold them
const FACTS_FULL: DepthFacts = { ...FACTS, noticeHours: 2, cancellation: { graceHours: 24, graceBps: 10000, earlyHours: 72, earlyBps: 7500, lateHours: 24, midBps: 5000 },
  fees: [['Winter tires', 'per_day', 1500, 7500], ['Baby seat', 'per_day', 1000, 5000], ['Late return', 'per_hour', 2500, null], ['Cleaning', 'flat', 7500, null], ['Heavy cleaning', 'flat', 25000, null],
    ['Pet cleaning', 'flat', 15000, null], ['Smoking', 'flat', 25000, null], ['Lost key or fob', 'per_item', 5000, null], ['Ticket administration', 'per_item', 2500, null], ['Declined payment', 'flat', 2500, null]]
    .map(([label, unit, a, c]) => ({ label: label as string, unit: unit as string, amountCents: a as number, capCents: c as number | null })) };
const FLEET12 = ['2024 Toyota Corolla', '2023 Honda Civic', '2023 Honda CR-V', '2024 Toyota RAV4', '2022 Hyundai Tucson', '2021 Kia Carnival', '2023 Tesla Model 3', '2022 Mercedes-Benz C300',
  '2023 BMW X3', '2022 Ford Escape', '2024 Nissan Rogue', '2023 Mazda CX-5'].map((n, i) => car(n, 4900 + i * 700));

test('fees, notice and cancelling come from the fee schedule and Program settings', () => {
  const d = buildDepth({ ...full, facts: FACTS_FULL });
  const r = d.sections.find((s) => s.id === 'requirements')!;
  assert.match(r.paras.join(' '), /Book at least 2 hours before pickup, for delivery to Mississauga/);
  assert.match(r.paras.join(' '), /Cancelling: 100% back within 24 hours of booking when pickup is 72 hours or more away; 75% back/);
  assert.ok(r.table!.rows.some((x) => x[0] === 'Winter tires' && x[1] === '$15 a day, up to $75'));
});

// Two sample pages, before and after (the report's word counts): a place hub with its lead, kit sections and questions
const hub = (slug: string, name: string, km: number): Hub => ({
  term: { slug: 'car-rental', vertical: 'rental', phrase: 'car rental', title: 'Car Rental', served: 'yes', landing_slug: null, lead_kind: null, service_code: null, intent_note: '', faq: [], canonical_path: null, landing_path: null },
  path: `/car-rental/${slug}`, place: { slug, kind: 'city', name, country: 'CA', region: 'CA-ON', region_name: 'Ontario', lat: 43.59, lng: -79.64, gta: true, landing_slug: null, iata: null, sources: { geonames: true } },
  ancestors: [], children: [], gta_members: null, nearby: [{ slug: 'brampton-on', kind: 'city', name: 'Brampton', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 18 }], landmarks: [],
  airport: { name: 'Toronto Pearson International Airport', iata: 'YYZ', slug: 'yyz', km: 9 }, origin: { lat: 43.65, lng: -79.38, label: 'our location' },
  delivery: { in_reach: true, km, reach_km: 80, fee_from_cents: 9500, per_km_cents: 100 }, cars: [], counts: { car_count: 4, real_cars: 4, min_daily_cents: 4900, min_weekly_cents: 29400, min_monthly_cents: 107800, min_delivery_cents: 9500 },
  real_cars: 4, disclaimer: null, service: null, related_terms: [], rental_terms: null, indexable: true, lastmod: '2026-11-01'
});
export function sampleCounts() {
  return [['Mississauga', 'mississauga-on', 24.6], ['Markham', 'markham-on', 27]].map(([name, slug, km]) => {
    const h = hub(slug as string, name as string, km as number);
    const c = hubCopy(h, { fill: (s) => s });
    const kit = writeKit(hubKit(h, name as string, TOKENS));
    const before = c.lead.reduce((n, p) => n + depthWordCount(p), 0) + kit.words + [...c.faq, ...kit.faq].slice(0, 8).reduce((n, q) => n + depthWordCount(q.question) + depthWordCount(q.answer), 0);
    const d = buildDepth({ ...full, facts: FACTS_FULL, cars: FLEET12, path: h.path, place: { ...PLACE, name: name as string, label: name as string, km: km as number, nearby: NEAR8 },
      pois: name === 'Mississauga' ? POIS_FULL : POIS_FULL.filter((q) => q.kind !== 'bus_stop'),
      related: { places: NEAR8.map((n) => ({ href: n.path, label: `Car rental in ${n.name}` })), cars: FLEET12.slice(0, 6).map((c) => ({ href: c.path, label: `${c.name} for rent` })), guides: full.related!.guides } });
    return { page: h.path, before, after: before + d.words };
  });
}
// a place's stops and hotels as the seo-data workflow loads them (example names, example.test style: no real business data)
const POIS_FULL = [
  ...['Cooksville GO', 'Port Credit GO', 'Dixie GO'].map((name, i) => ({ kind: 'go_station' as const, agency: 'GO Transit', name, km: 1.2 + i * 1.3, source: 'gtfs' as const, attribution: 'Stops: GO Transit GTFS (Metrolinx Open Data Licence)' })),
  ...['Hurontario St at Dundas St', 'Dundas St at Mavis Rd', 'Square One Bus Terminal', 'Burnhamthorpe Rd at Confederation Pkwy', 'Mavis Rd at Eglinton Ave'].map((name, i) => ({ kind: 'bus_stop' as const, agency: 'MiWay', name, km: 0.3 + i * 0.6, source: 'gtfs' as const, attribution: 'Stops: MiWay GTFS (City of Mississauga Open Data Licence)' })),
  ...['Example Hotel One', 'Example Hotel Two', 'Example Suites Three', 'Example Inn Four', 'Example Hotel Five'].map((name, i) => ({ kind: 'hotel' as const, agency: null, name, km: 0.8 + i * 0.7, source: 'osm' as const, attribution: 'Hotels: © OpenStreetMap contributors (ODbL)' }))
];
const NEAR8 = ['Brampton', 'Oakville', 'Milton', 'Etobicoke', 'Port Credit', 'Streetsville', 'Meadowvale', 'Malton'].map((name, i) => ({ name, path: `/car-rental/${name.toLowerCase().replace(/ /g, '-')}`, km: 8 + i * 3 }));

test('sample pages: the depth sections make a place page about 3 to 5 times longer', () => {
  for (const s of sampleCounts()) {
    const ratio = s.after / s.before;
    if (process.env.SHOW_WORDS) console.log(`${s.page}: ${s.before} words before, ${s.after} after (${ratio.toFixed(1)}x)`);
    assert.ok(ratio >= 2.5, `${s.page}: ${s.before} -> ${s.after}`);
  }
});
