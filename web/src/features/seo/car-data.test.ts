// Release 36 (2001): the new free sources' parsers, the parking parser and the car data writing kit.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { complaintRows, curatedSpecRows, osmParking, recallItemRows, tcRecallRows, vpicCanadaRows, wikidataRows } from './seo-data.ts';
import { kitRatings, kitSentences, kitTable, parkability, type KitSpec } from './car-kit.ts';
import { buildDepth } from './depth.ts';

const AT = '2026-11-11T00:00:00.000Z';
const T = { make: 'Cadillac', model: 'CTS', year: 2015 };

test('vPIC Canadian specs: the model\'s dimensions in mm (cm in the answer) and its weight, with the source', () => {
  const rows = vpicCanadaRows({ Results: [{ Specs: [{ Name: 'Model', Value: 'ATS' }, { Name: 'OL', Value: '464' }] }, { Specs: [{ Name: 'Model', Value: 'CTS' }, { Name: 'MYR', Value: '2015' }, { Name: 'OL', Value: '496.6' }, { Name: 'OW', Value: '183.3' }, { Name: 'OH', Value: '' }, { Name: 'CW', Value: '1640' }] }] }, T, AT);
  assert.deepEqual(rows.map((r) => [r.field, r.value]), [['length_mm', '4966'], ['width_mm', '1833'], ['curb_kg', '1640']]);
  assert.equal(rows[0]!.source, 'nhtsa_vpic'); assert.match(rows[0]!.source_url, /^https:\/\/vpic/);
});

test('NHTSA recall campaigns and complaints: one row per campaign, the most-reported components as common problems', () => {
  const r = recallItemRows({ results: [{ NHTSACampaignNumber: '15V123000', Component: 'ELECTRICAL SYSTEM: WIRING' }, { NHTSACampaignNumber: '', Component: 'X' }] }, T, AT);
  assert.deepEqual(r.map((x) => [x.code, x.value]), [['15V123000', 'Electrical System']]);
  const c = complaintRows({ results: [...Array(7).fill({ components: 'ENGINE,ELECTRICAL SYSTEM' }), ...Array(2).fill({ components: 'STEERING' })] }, T, AT);
  assert.deepEqual(c.map((x) => x.value), ['Electrical System (7 complaints to NHTSA)', 'Engine (7 complaints to NHTSA)']);
});

test('Transport Canada recalls: the count and each campaign, from the Name and Value list answer', () => {
  const ans = { ResultSet: [[{ Name: 'Recall number', Value: { Literal: '2015123' } }, { Name: 'System Type', Value: { Literal: 'AIR BAGS' } }], [{ Name: 'Recall number', Value: { Literal: '2015123' } }]] };
  const rows = tcRecallRows(ans, T, AT);
  assert.deepEqual(rows.map((x) => [x.field, x.value, x.code ?? null]), [['tc_recalls', '1', null], ['recall_item', 'Air Bags', 'TC 2015123']]);
  assert.deepEqual(tcRecallRows({ ResultSet: [] }, T, AT).map((x) => x.value), ['0']);
});

test('Wikidata: production years and plants of the matching model, never a year before production started', () => {
  const b = (o: Record<string, string>) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, { value: v }]));
  const ans = { results: { bindings: [b({ model: 'http://www.wikidata.org/entity/Q1', modelLabel: 'Cadillac CTS', start: '2002-01-01', end: '2019-01-01', plantLabel: 'Lansing Grand River Assembly' }), b({ model: 'http://www.wikidata.org/entity/Q2', modelLabel: 'Escalade', start: '1998-01-01' })] } };
  const rows = wikidataRows(ans, [T, { ...T, model: 'XT9' }], AT);
  assert.deepEqual(rows.map((r) => [r.field, r.value]), [['production_start', '2002'], ['production_end', '2019'], ['assembly_plant', 'Lansing Grand River Assembly']]);
  assert.equal(rows[0]!.source_url, 'https://www.wikidata.org/wiki/Q1');
});

test('the curated CSV takes the new fields and still refuses a row without its source', () => {
  const r = curatedSpecRows([{ make: 'Cadillac', model: 'CTS', year: '2015', field: 'msrp_cad', value: '52895', source: 'oem', source_url: 'https://example.test/p' }, { make: 'Cadillac', model: 'CTS', year: '2015', field: 'carplay', value: 'Yes', source: 'oem', source_url: '' }], AT);
  assert.equal(r.rows.length, 1); assert.equal(r.rejected, 1);
});

test('OpenStreetMap parking: public lots with their detail and streets with parking lanes; private lots left out', () => {
  const rows = osmParking({ elements: [
    { type: 'way', id: 1, center: { lat: 43.65, lon: -79.38 }, tags: { amenity: 'parking', name: 'Green P 36', parking: 'multi-storey', fee: 'yes', capacity: '400' } },
    { type: 'way', id: 2, center: { lat: 43.65, lon: -79.38 }, tags: { amenity: 'parking', access: 'private', name: 'Condo lot' } },
    { type: 'node', id: 3, lat: 43.6, lon: -79.3, tags: { amenity: 'parking' } },
    { type: 'way', id: 4, center: { lat: 43.66, lon: -79.39 }, tags: { highway: 'residential', name: 'Beverley Street', 'parking:both': 'lane', 'parking:both:maxstay': '3 hours' } },
    { type: 'way', id: 5, center: { lat: 43.66, lon: -79.39 }, tags: { highway: 'residential', name: 'No Park Road', 'parking:both': 'no' } }
  ] }, AT);
  assert.deepEqual(rows.map((r) => [r.kind, r.name]), [['parking_lot', 'Green P 36'], ['street_parking', 'Beverley Street']]);
  assert.deepEqual(rows[0]!.detail, { parking: 'multi-storey', fee: 'yes', capacity: 400 });
  assert.equal(rows[1]!.detail!.maxstay, '3 hours');
});

const S = (field: string, value: string, code?: string): KitSpec => ({ field, value, code, source: 'oem', source_url: 'https://example.test/s' });
test('the writing kit: the table in its order, sentences only from values, ratings with their basis, parkability', () => {
  const specs = [S('length_mm', '4966'), S('width_mm', '1833'), S('fuel_combined_l100', '10.2'), S('msrp_cad', '52895'), S('production_start', '2014'), S('production_end', '2019'),
    S('assembly_plant', 'Lansing Grand River Assembly'), S('carplay', 'Yes'), S('android_auto', 'Yes'), S('safety_overall', '5'), S('recalls', '2')];
  assert.deepEqual(kitTable(specs).slice(0, 2), [['MSRP (Canada)', '$52,895 CAD'], ['Fuel economy, combined', '10.2 L/100 km']]);
  const text = kitSentences('2015 Cadillac CTS', specs).join(' ');
  assert.match(text, /was built from 2014 to 2019 at Lansing Grand River Assembly/);
  assert.match(text, /Apple CarPlay and Android Auto/);
  assert.doesNotMatch(text, /suitcases|Charging/);
  const r = Object.fromEntries(kitRatings(specs).map((x) => [x.label, x.score]));
  assert.equal(r['Crash safety'], 10); assert.equal(r['Recall record'], 7); assert.equal(r['Phone connection'], 10);
  assert.equal(r.Parkability, 5.1);
  assert.equal(parkability([S('width_mm', '1800')]), null);
  assert.ok(parkability([S('length_mm', '4100')])!.score === 10);
});

test('the depth sections: the ratings section and a parking section from the page data', () => {
  const facts = { brand: 'CarmaCars', minAge: 21, youngBands: [], licenceClasses: ['G'], otherLicenceReview: false, depositTiersCents: [50000], tollFeeCents: null, additionalDriverBps: null,
    deductibleCents: null, hstBps: 1300, maxDays: 30, weekFrom: 7, coverOptions: [], airports: [] };
  const d = buildDepth({ path: '/x', facts, cars: [], vehicle: { name: '2015 Cadillac CTS', specs: [S('length_mm', '4966'), S('safety_overall', '5')] },
    place: { name: 'Downtown', label: 'Downtown', kind: 'neighbourhood', region: 'CA-ON', km: 2, originLabel: 'our location', inReach: true, reachKm: 80, deliveryFromCents: null },
    pois: [{ kind: 'parking_lot', agency: null, name: 'Green P 36', km: 0.4, source: 'osm', attribution: 'x', detail: { parking: 'multi-storey', capacity: 400, fee: 'yes' } }] });
  assert.ok(d.sections.some((x) => x.id === 'ratings'));
  const pk = d.sections.find((x) => x.id === 'parking')!;
  assert.match(pk.paras[0]!, /Green P 36, 0\.4 km \(garage, 400 spaces, paid\)/);
});
