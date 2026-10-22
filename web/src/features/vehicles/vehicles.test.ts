// The vehicle pages (migration 0092): slugs, unit conversions, the gate, the catalog normaliser and the page text.
//   node --test --experimental-strip-types src/features/vehicles/vehicles.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { costPer100km, driveLabel, engineLabel, kwh100miTo100km, miToKm, modelKey, mpgToL100, slugify, transLabel, trimSlug } from './units.ts';
import { gateRules, parentPath, vpageGate, type GateSettings } from './gate.ts';
import { buildCatalog, parseCsv, parsePopular, parseTrimList, specialTokens } from './normalise.ts';
import { descriptionFor, ratingRange, specs, titleFor, trimDiffs, yearChanges, type Variant } from './content.ts';

const here = new URL('.', import.meta.url).pathname;
const S = { gas_cents: 155, premium_extra_cents: 20, elec_cents: 15 };

test('slugs are lowercase, stable and match app.slugify', () => {
  assert.equal(slugify('Mercedes-Benz'), 'mercedes-benz');
  assert.equal(slugify('Land Rover'), 'land-rover');
  assert.equal(slugify('  CR-V '), 'cr-v');
  assert.equal(slugify('Citroën C4'), 'citroen-c4');
  assert.equal(slugify('Model 3'), 'model-3');
  assert.equal(slugify('ID.4'), 'id-4');
  assert.equal(slugify(''), '');
  assert.equal(trimSlug('EX+'), 'ex-plus');
  assert.equal(trimSlug('Trendline+'), 'trendline-plus');
  assert.notEqual(trimSlug('EX+'), trimSlug('EX'));
  assert.equal(trimSlug('C 300 4MATIC'), 'c-300-4matic');
  assert.equal(modelKey('F-150'), modelKey('F150'));
  assert.equal(modelKey('CX-5'), 'cx5');
});

test('EPA miles per gallon become litres per 100 km; kWh and miles convert', () => {
  assert.equal(mpgToL100(30), 7.8);
  assert.equal(mpgToL100(23.5), 10);
  assert.equal(mpgToL100(100), 2.4);
  assert.equal(mpgToL100(0), null);
  assert.equal(mpgToL100(null), null);
  assert.equal(kwh100miTo100km(26), 16.2);
  assert.equal(miToKm(333), 536);
  assert.equal(costPer100km({ l100: 7.8, gasCents: 155, elecCents: 15 }), 1209);
  assert.equal(costPer100km({ l100: 8, gasCents: 155, elecCents: 15, premium: true, premiumExtraCents: 20 }), 1400);
  assert.equal(costPer100km({ kwh100: 16.2, gasCents: 155, elecCents: 15 }), 243);
  assert.equal(costPer100km({ gasCents: 155, elecCents: 15 }), null);
});

test('engine, drive and gearbox words', () => {
  assert.equal(engineLabel({ displ: 1.4, cyl: 4, turbo: true }), '1.4L 4-cylinder turbo');
  assert.equal(engineLabel({ ev: true }), 'Electric motor');
  assert.equal(engineLabel({ displ: 2.5, cyl: 4, hybrid: true }), '2.5L 4-cylinder hybrid');
  assert.equal(driveLabel('Front-Wheel Drive'), 'Front-wheel drive');
  assert.equal(driveLabel('4-Wheel or All-Wheel Drive'), 'All-wheel drive');
  assert.equal(driveLabel('4-Wheel Drive'), 'Four-wheel drive');
  assert.equal(driveLabel('Rear-Wheel Drive'), 'Rear-wheel drive');
  assert.equal(transLabel('Automatic (S8)'), '8-speed automatic');
  assert.equal(transLabel('Automatic (variable gear ratios)'), 'Automatic (CVT)');
  assert.equal(transLabel('Manual 6-spd'), '6-speed manual');
});

test('the gate: everything indexed by default; the rules when an Admin turns them on', () => {
  const all: GateSettings = { index_mode: 'all', model_min_years: 2, popular_from_year: 2015, year_min_cars: 1, trim_min_cars: 1 };
  for (const l of ['make', 'model', 'year', 'trim'] as const) assert.equal(vpageGate(l, {}, all), true, l);
  const r: GateSettings = { ...all, index_mode: 'rules' };
  assert.equal(vpageGate('make', {}, r), true);
  assert.equal(vpageGate('model', { years: 1 }, r), false);
  assert.equal(vpageGate('model', { years: 2 }, r), true);
  assert.equal(vpageGate('model', { years: 1, realCars: 1 }, r), true);
  assert.equal(vpageGate('year', { year: 2020, popular: false }, r), false);
  assert.equal(vpageGate('year', { year: 2020, popular: true }, r), true);
  assert.equal(vpageGate('year', { year: 2014, popular: true }, r), false);
  assert.equal(vpageGate('year', { year: 2012, realCars: 1 }, r), true);
  assert.equal(vpageGate('trim', {}, r), false);
  assert.equal(vpageGate('trim', { realCars: 1 }, r), true);
  assert.equal(vpageGate('trim', { realCars: 1 }, { ...r, trim_min_cars: 2 }), false);
  assert.equal(parentPath('/cars/volkswagen/jetta/2020/sportline'), '/cars/volkswagen/jetta/2020');
  assert.equal(parentPath('/cars/volkswagen/jetta/2020'), '/cars/volkswagen/jetta');
  assert.equal(parentPath('/cars/volkswagen/jetta'), '/cars/volkswagen');
  assert.equal(gateRules(all).length, 1);
  assert.equal(gateRules(r).length, 4);
});

test('EPA model words beyond the base model tie a trim to a powertrain', () => {
  assert.deepEqual(specialTokens('Jetta GLI', 'Jetta'), ['gli']);
  assert.deepEqual(specialTokens('Jetta', 'Jetta'), []);
  assert.deepEqual(specialTokens('F150 Pickup 4WD', 'F150'), []);
  assert.deepEqual(specialTokens('Model 3 Long Range AWD', 'Model 3'), ['long', 'range']);
  assert.deepEqual(specialTokens('C300 4matic', 'C-Class'), ['c300']);
  assert.deepEqual(specialTokens('Camry Hybrid LE', 'Camry'), ['hybrid', 'le']);
  assert.deepEqual(specialTokens('Camry Hybrid SE/XLE/XSE', 'Camry'), ['hybrid', 'se|xle|xse']);
  assert.deepEqual(specialTokens('Corolla Hatchback XSE', 'Corolla'), ['xse']);
  assert.deepEqual(specialTokens('Mustang Mach-E AWD', 'Mustang Mach-E'), []);
});

test('the fixture CSV builds the catalog with the Canadian trims', () => {
  const rows = parseCsv(readFileSync(new URL('../../../scripts/catalog/fixture/vehicles-fixture.csv', import.meta.url), 'utf8'));
  assert.ok(rows.length > 20, 'fixture rows');
  const trims = parseTrimList(readFileSync(new URL('../../../scripts/catalog/canada-trims.txt', import.meta.url), 'utf8'));
  const popular = parsePopular(readFileSync(new URL('../../../scripts/catalog/popular.txt', import.meta.url), 'utf8'));
  const c = buildCatalog(rows, { years: [2010, 2027], trimLines: trims, popular });
  const jetta = c.years.find((y) => y.make === 'volkswagen' && y.model === 'jetta' && y.year === 2020);
  assert.ok(jetta, 'the 2020 Jetta');
  assert.ok(jetta!.variants.every((v) => v.l100_comb === null || (v.l100_comb > 3 && v.l100_comb < 20)), 'plausible L/100 km');
  assert.ok(c.trim_lines.some((t) => t.make === 'volkswagen' && t.model === 'jetta' && t.trims.includes('Sportline')), 'the Canadian Sportline');
  assert.ok(c.models.every((m) => /^[a-z0-9]+(-[a-z0-9]+)*$/.test(m.slug)), 'model slugs');
  assert.ok(c.popular.some((p) => p.make === 'toyota' && p.model === 'corolla'), 'popular Corolla');
  assert.ok(c.models.find((m) => m.make === 'mercedes-benz')?.aliases.includes('c300'), 'C300 finds the C-Class');
});

test('the trim list refuses a malformed line, an unknown make and a trim named twice', () => {
  assert.throws(() => parseTrimList('Toyota | Corolla | 20x0 | LE'));
  assert.throws(() => parseTrimList('Toyoda | Corolla | 2020 | LE'));
  assert.throws(() => parseTrimList('Toyota | Corolla | 2020 | LE, LE'));
  assert.deepEqual(parseTrimList('# c\nToyota | Corolla | 2020-2022 | L, LE\n'), [{ make: 'toyota', model: 'Corolla', from: 2020, to: 2022, trims: ['L', 'LE'] }]);
  void here;
});

const v = (o: Partial<Variant> & { id: number }): Variant => ({ epa_model: 'X', displ: 2, cyl: 4, turbo: false, super: false, drive: 'Front-Wheel Drive', trans: 'Automatic (S8)', fuel: 'gasoline', vclass: 'Compact Cars',
  l100_city: 9, l100_hwy: 7, l100_comb: 8, kwh100: null, ev_range_km: null, co2_g_km: 190, ...o });

test('specs merge duplicates, cost the driving and say the range', () => {
  const sp = specs([v({ id: 1 }), v({ id: 2, l100_comb: 8.2 }), v({ id: 3, displ: 2.0, turbo: true, fuel: 'premium', l100_comb: 9.4 })], S);
  assert.equal(sp.length, 2);
  assert.equal(sp[0]!.l100_comb, 8.1);
  assert.equal(sp[0]!.cost100, Math.round(8.1 * 155));
  assert.equal(sp[1]!.cost100, Math.round(9.4 * 175));
  assert.equal(ratingRange(sp), '8.1 to 9.4 L/100 km');
});

test('what changed between years, and how a trim differs, come from the data', () => {
  const cur = specs([v({ id: 1, l100_comb: 7.5 }), v({ id: 2, displ: 2.5, l100_comb: 8.9 })], S), prev = specs([v({ id: 9, l100_comb: 8 })], S);
  const ch = yearChanges({ year: 2021, cur, prevYear: 2020, prev, curTrims: ['LE', 'XLE'], prevTrims: ['LE'] });
  assert.ok(ch.some((x) => /New for 2021: 2\.5L/.test(x)), ch.join(' | '));
  assert.ok(ch.some((x) => /down from 8\.0 in 2020/.test(x)), ch.join(' | '));
  assert.ok(ch.some((x) => /Trims new in Canada for 2021: XLE/.test(x)));
  const variants = [v({ id: 1 }), v({ id: 2, displ: 2.0, turbo: true, drive: 'All-Wheel Drive', l100_comb: 9 })];
  const sib = [{ slug: 'le', name: 'LE', rank: 1, variant_ids: [1], path: '/a' }, { slug: 'se', name: 'SE', rank: 2, variant_ids: [1], path: '/b' }, { slug: 'xse', name: 'XSE AWD', rank: 3, variant_ids: [2], path: '/c' }];
  const d = trimDiffs(sib[0]!, sib, variants, S);
  assert.match(d[0]!, /trim 1 of 3.*entry trim/);
  assert.ok(d.some((x) => /shares its EPA-rated powertrain with the SE/.test(x)), d.join(' | '));
  assert.ok(d.some((x) => /XSE AWD has the 2\.0L 4-cylinder turbo/.test(x)), d.join(' | '));
  const top = trimDiffs(sib[2]!, sib, variants, S);
  assert.ok(top.some((x) => /only trim with all-wheel drive/.test(x)), top.join(' | '));
});

test('titles and descriptions are unique per page and never use an em dash', () => {
  const pages = [
    { make: 'Volkswagen' }, { make: 'Volkswagen', model: 'Jetta' }, { make: 'Volkswagen', model: 'Jetta', year: 2020 }, { make: 'Volkswagen', model: 'Jetta', year: 2021 },
    { make: 'Volkswagen', model: 'Jetta', year: 2020, trim: 'Sportline' }, { make: 'Volkswagen', model: 'Jetta', year: 2020, trim: 'Highline' }
  ];
  const titles = pages.map(titleFor), descs = pages.map((p) => descriptionFor({ ...p, cars: 0 }));
  assert.equal(new Set(titles).size, titles.length);
  assert.equal(new Set(descs).size, descs.length);
  assert.equal(titles[4], 'Rent a 2020 Volkswagen Jetta Sportline in {{city}} | {{brand}}');
  for (const s of [...titles, ...descs]) assert.ok(!s.includes('—') && !s.includes(' – '), s);
});
