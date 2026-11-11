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
  assert.match(words(c), /Where is CarmaCars located\? CarmaCars is in Toronto, and we deliver to Port Credit, Mississauga\./);
  assert.ok(c.description.length >= 70 && c.description.length <= 170, c.description);
});

test('a far place: we serve the Toronto area, no delivery promise, a request', () => {
  const h = base({ kind: 'city', km: 1360, inReach: false, place: { ...base().place, kind: 'city', name: 'Thunder Bay', slug: 'thunder-bay-on' } });
  const c = hubCopy(h, fill);
  assert.match(words(c), /serves the Toronto area/);
  assert.match(words(c), /rents cars from Toronto, about 1,360 km from Thunder Bay/);
  assert.doesNotMatch(words(c), /Delivered from|Delivery starts/);
});

test('every family: the house style (no long dash, no exclamation, the brand), and buying help never sells or lends', () => {
  for (const vertical of ['rental', 'sale', 'detailing', 'bodyshop'] as const) for (const inReach of [true, false]) {
    const c = hubCopy(base({ vertical, inReach, km: inReach ? 19 : 500 }), fill);
    const w = words(c);
    assert.doesNotMatch(w, /[‒–—―!]/, `${vertical} ${inReach}`);
    assert.doesNotMatch(w, /carmacars|Carma Cars|18122211/, `${vertical}`);
    assert.ok(c.title.length <= 70, c.title);
    if (vertical === 'sale') { assert.match(w, /Rent the model/); assert.doesNotMatch(w, /we (sell|lend|lease|finance)\b/i); }
  }
});

test('outside Canada: the state in the label; a short description says the prices are in Canadian dollars', () => {
  const h = base({ place: { ...base().place, country: 'US', region: 'US-NY', name: 'Buffalo', kind: 'city' }, kind: 'city', inReach: false, km: 100 });
  assert.equal(placeLabel(h), 'Buffalo, NY');
  assert.match(hubCopy({ ...h, term: { ...h.term, slug: 'used-cars', vertical: 'sale', title: 'Used Cars', phrase: 'used cars' } }, fill).description, /Canadian dollars|Rent the model/);
});

test('0121: mechanical work we arrange never says CarmaCars does it, offers a rental, and has no questions', () => {
  const term = { slug: 'oil-change', vertical: 'bodyshop' as const, phrase: 'oil change', title: 'Oil Change', served: 'request' as const, landing_slug: null, lead_kind: 'auto_service',
    service_code: null, intent_note: 'An oil and filter change, done by a trusted shop we arrange, not by CarmaCars.', faq: [], canonical_path: null, landing_path: null };
  const near = hubCopy(base({ term, vertical: 'bodyshop' }), fill);
  assert.equal(near.h1, 'Oil Change in Port Credit, Mississauga');
  assert.match(words(near), /CarmaCars arranges this work with a trusted shop/);
  assert.match(words(near), /trusted shop/);
  assert.match(near.description, /rental car while yours is in/);
  assert.doesNotMatch(words(near), /CarmaCars (does|do) oil|we (do|change|repair|fix)\b|Does CarmaCars have a location/);
  assert.equal(near.faq.length, 0);
  assert.ok(near.description.length <= 170, near.description);
  const far = hubCopy(base({ term, vertical: 'bodyshop', km: 500, inReach: false, kind: 'city' }), fill);
  assert.match(words(far), /arranges this work with trusted shops/);
  assert.match(words(far), /a person replies with the shops we know there/);
  assert.equal(far.faq.length, 0);
});

test('0522: the alternative terms: "Turo Alternative in <place>", the not-affiliated sentence on the page, nothing about the other company', () => {
  const alt = (slug: string, title: string, note: string) => hubCopy(base({ term: { ...base().term, slug, title, phrase: title.toLowerCase(), landing_slug: null, intent_note: note,
    faq: [{ question: `Is CarmaCars part of ${title.split(' ')[0]}?`, answer: `No. CarmaCars is not affiliated with, approved or endorsed by ${title.split(' ')[0]}.` }] } }), fill);
  const turo = alt('turo-alternative', 'Turo Alternative', 'Rent from CarmaCars directly. CarmaCars is not affiliated with, approved or endorsed by Turo.');
  assert.equal(turo.title, 'Turo Alternative in Port Credit, Mississauga | CarmaCars');
  assert.equal(turo.h1, 'Turo Alternative in Port Credit, Mississauga');
  assert.match(words(turo), /not affiliated with, approved or endorsed by Turo/);
  const luup = alt('luup-alternative', 'Luup Alternative for Rideshare Drivers', 'A car for Uber, Lyft or delivery work. CarmaCars is not affiliated with, approved or endorsed by any of them.');
  assert.ok(luup.title.startsWith('Luup Alternative for Rideshare Drivers in Port Credit') && luup.title.length <= 70, luup.title);
  assert.ok(luup.faq.some((q) => /not affiliated/.test(q.answer)));
});

test('release 28: each place page reads differently, with its drive time, landmarks, nearby places and real cars', async () => {
  const { driveMinutes, variant } = await import('./copy.ts');
  assert.equal(driveMinutes(19), 30);
  assert.ok(driveMinutes(3) >= 10);
  const picks = new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map((k) => variant(`${k}-place|suv-rental`, 3)));
  assert.ok(picks.size >= 2, 'neighbouring pages do not all read the same');
  const car = (make: string, model: string, cents: number) => ({ year: 2024, make, model, daily_rate_cents: cents, is_sample: false }) as unknown as Hub['cars'][number];
  const h = base({ landmarks: [{ name: 'Port Credit Lighthouse', km: 1 }], nearby: [{ slug: 'lakeview', kind: 'neighbourhood', name: 'Lakeview', country: 'CA', region: 'CA-ON', region_name: 'Ontario', km: 3 }],
    cars: [car('Toyota', 'RAV4', 8900), car('Honda', 'Civic', 5900)] });
  const w = words(hubCopy(h, fill));
  assert.match(w, /Port Credit Lighthouse/);
  assert.match(w, /Lakeview/);
  assert.match(w, /the 2024 Honda Civic from \$59 a day and the 2024 Toyota RAV4 from \$89 a day/);
  assert.match(w, /minutes by car/);
  assert.doesNotMatch(w, /—/);
});
