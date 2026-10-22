// The words of a place page (migration 0095): from the data only, honest about distance, never a local branch.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hubCopy, placeLabel } from './copy.ts';
import type { Hub } from './data.ts';

const base = (o: Partial<Hub> & { kind?: Hub['place']['kind']; km?: number | null; inReach?: boolean; vertical?: Hub['term']['vertical'] } = {}): Hub => ({
  term: { slug: 'suv-rental', vertical: o.vertical ?? 'rental', phrase: 'SUV rental', title: 'SUV Rental', served: 'yes', landing_slug: 'suv', lead_kind: null, service_code: null,
    intent_note: 'SUVs for families, luggage and winter roads.', faq: [], canonical_path: null, landing_path: null },
  path: '/car-rental/suv-rental/x', place: { slug: 'port-credit-mississauga-on', kind: o.kind ?? 'neighbourhood', name: 'Port Credit', country: 'CA', region: 'CA-ON', region_name: 'Ontario',
    lat: 43.55, lng: -79.58, gta: true, landing_slug: null, iata: null, sources: { geonames: true } },
  ancestors: [{ slug: 'canada', kind: 'country', name: 'Canada', country: 'CA', region: null, region_name: null }, { slug: 'mississauga', kind: 'city', name: 'Mississauga', country: 'CA', region: 'CA-ON', region_name: 'Ontario' }],
  children: [], gta_members: null, nearby: [], landmarks: [], airport: { name: 'Toronto Pearson International Airport', iata: 'YYZ', slug: 'yyz-airport', km: 12 },
  origin: { lat: 43.65, lng: -79.38, label: 'central Toronto' }, delivery: { in_reach: o.inReach ?? true, km: o.km === undefined ? 19 : o.km, reach_km: 80, fee_from_cents: 7500, per_km_cents: 0 },
  cars: [], counts: { car_count: 2, real_cars: 2, min_daily_cents: 5000, min_weekly_cents: null, min_monthly_cents: null, min_delivery_cents: 7500 }, real_cars: 2, disclaimer: null, service: null,
  related_terms: [], rental_terms: [], indexable: true, lastmod: '2026-10-22', ...o });
const fill = { fill: (s: string) => s };
const words = (c: ReturnType<typeof hubCopy>) => [c.title, c.description, c.h1, ...c.lead, ...c.faq.flatMap((q) => [q.question, q.answer])].join(' ');

test('a neighbourhood near us: its city in the label, the real distance, delivery price and airport', () => {
  const h = base();
  assert.equal(placeLabel(h), 'Port Credit, Mississauga');
  const c = hubCopy(h, fill);
  assert.equal(c.title, 'SUV Rental in Port Credit, Mississauga | CarmaCars');
  assert.match(words(c), /about 19 km from central Toronto/);
  assert.match(words(c), /\$75/);
  assert.match(words(c), /Toronto Pearson International Airport \(YYZ\), about 12 km away/);
  assert.match(words(c), /Does CarmaCars have a location in Port Credit, Mississauga\? No\./);
  assert.ok(c.description.length >= 70 && c.description.length <= 170, c.description);
});

test('a far place: we serve the Toronto area, no delivery promise, a request', () => {
  const h = base({ kind: 'city', km: 1360, inReach: false, place: { ...base().place, kind: 'city', name: 'Thunder Bay', slug: 'thunder-bay-on' } });
  const c = hubCopy(h, fill);
  assert.match(words(c), /serves the Toronto area/);
  assert.match(words(c), /no location in Thunder Bay/);
  assert.doesNotMatch(words(c), /Delivered from|Delivery starts/);
});

test('every family: the house style (no long dash, no exclamation, the brand), and buying help never sells or lends', () => {
  for (const vertical of ['rental', 'sale', 'detailing', 'bodyshop'] as const) for (const inReach of [true, false]) {
    const c = hubCopy(base({ vertical, inReach, km: inReach ? 19 : 500 }), fill);
    const w = words(c);
    assert.doesNotMatch(w, /[‒–—―!]/, `${vertical} ${inReach}`);
    assert.doesNotMatch(w, /carmacars|Carma Cars|18122211/, `${vertical}`);
    assert.ok(c.title.length <= 70, c.title);
    if (vertical === 'sale') { assert.match(w, /does not sell, finance or lease/); assert.doesNotMatch(w, /we (sell|lend|lease|finance)\b/i); }
  }
});

test('outside Canada: the state in the label; a short description says the prices are in Canadian dollars', () => {
  const h = base({ place: { ...base().place, country: 'US', region: 'US-NY', name: 'Buffalo', kind: 'city' }, kind: 'city', inReach: false, km: 100 });
  assert.equal(placeLabel(h), 'Buffalo, NY');
  assert.match(hubCopy({ ...h, term: { ...h.term, slug: 'used-cars', vertical: 'sale', title: 'Used Cars', phrase: 'used cars' } }, fill).description, /Canadian dollars|does not sell/);
});
