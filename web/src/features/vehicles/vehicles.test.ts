// The vehicle pages (migration 0097): slugs, unit conversions, the gate, the catalog normaliser and the page text.
//   node --test --experimental-strip-types src/features/vehicles/vehicles.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { costPer100km, driveLabel, engineLabel, kwh100miTo100km, miToKm, modelKey, mpgToL100, slugify, transLabel, trimSlug } from './units.ts';
import { gateRules, parentPath, vpageGate, type GateSettings } from './gate.ts';
import { batches, buildCatalog, makeName, parseCsv, parsePopular, parseTrimList, specialTokens } from './normalise.ts';
import { buyDescriptionOptions, buyTitleOptions, descriptionFor, descriptionOptions, dimsFor, fit, mpgImperial, ratingRange, shortPlace, specs, statRows, termDescriptionOptions, tierDescriptionOptions, tierTitleOptions, titleFor, titleOptions, trimDiffs, yearChanges, type Variant } from './content.ts';

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

test('the trim list refuses a malformed line, a missing make and a trim named twice', () => {
  assert.throws(() => parseTrimList('Toyota | Corolla | 20x0 | LE'));
  assert.throws(() => parseTrimList(' | Corolla | 2020 | LE'));
  assert.throws(() => parseTrimList('Toyota | Corolla | 2020 | LE, LE'));
  assert.deepEqual(parseTrimList('# c\nToyota | Corolla | 2020-2022 | L, LE\n'), [{ make: 'toyota', model: 'Corolla', from: 2020, to: 2022, trims: ['L', 'LE'] }]);
  void here;
});

test('every make and every year: shown names, vPIC models and years, batches by size', () => {
  assert.equal(makeName('McLaren Automotive'), 'McLaren');
  assert.equal(makeName('FIAT'), 'Fiat');
  assert.equal(makeName('JBA Motorcars, Inc.'), 'JBA Motorcars');
  assert.equal(makeName('Lamborghini'), 'Lamborghini');
  assert.equal(makeName('  '), null);
  const row = (o: Record<string, string>) => ({ id: '1', year: '1985', make: 'Ferrari', model: 'Testarossa', baseModel: 'Testarossa', fuelType: 'Regular', atvType: '', displ: '4.9', cylinders: '12',
    drive: 'Rear-Wheel Drive', trany: 'Manual 5-spd', VClass: 'Two Seaters', city08: '9', highway08: '14', comb08: '11', ...o });
  const rows = [row({}), row({ id: '2', year: '1986' }), row({ id: '3', year: '1990', make: 'Chevrolet', model: 'Silverado C15 2WD', baseModel: 'Silverado', VClass: 'Standard Pickup Trucks 2WD' })];
  const vpic = new Map([['ferrari', new Map([[1983, ['Testarossa', 'Mondial']]])], ['chevrolet', new Map([[1990, ['Silverado 2500', 'Express']]])]]);
  const c = buildCatalog(rows, { years: [1981, 2027], vpic });
  assert.deepEqual(c.makes.map((m) => m.slug), ['chevrolet', 'ferrari'], 'an exotic make is in');
  assert.deepEqual(c.years.filter((y) => y.make === 'ferrari' && y.model === 'testarossa').map((y) => y.year), [1983, 1985, 1986], 'EPA years and a vPIC year before 1984');
  assert.ok(c.models.some((m) => m.make === 'ferrari' && m.slug === 'mondial' && m.sources.join() === 'vpic'), 'a model only vPIC has');
  assert.ok(c.models.find((m) => m.slug === 'silverado')?.aliases.includes('silverado2500'), 'a size of an EPA model is that model');
  assert.ok(!c.models.some((m) => m.slug === 'silverado-2500'), 'no second Silverado');
  const big = { ...c, trim_lines: [{ make: 'ferrari', model: 'testarossa', from: 1985, to: 1986, trims: ['Base'] }] };
  const bs = batches(big, 300);
  assert.ok(bs.length > c.makes.length, 'a make is split when its batch is large');
  assert.equal(bs.filter((b) => b.make.slug === 'ferrari' && b.trim_lines).length, 1, 'trim lines with the first batch only');
  assert.equal(bs.reduce((n, b) => n + b.years.length, 0), c.years.length, 'every year once');
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

test('city, colour and /buy pages: unique titles and descriptions across a sample, and the fallbacks keep the place', () => {
  const cities = ['Toronto', 'Downtown Toronto', 'North York', 'Scarborough', 'Etobicoke', 'Mississauga', 'Brampton', 'Vaughan', 'Markham', 'Richmond Hill', 'Oakville',
    'Toronto Pearson Airport (YYZ)', 'Billy Bishop Airport (YTZ)', 'Union Station'];
  const colours = ['Black', 'White', 'Silver', 'Grey', 'Blue', 'Red', 'Green', 'Brown', 'Beige', 'Gold', 'Orange', 'Yellow'];
  const trims = [{ make: 'Volkswagen', model: 'Jetta', year: 2020, trim: 'Sportline' }, { make: 'Mercedes-Benz', model: 'GLE-Class', year: 2023, trim: 'AMG GLE 53 4MATIC+' },
    { make: 'Toyota', model: 'Camry', year: 2023, trim: 'Hybrid SE' }];
  const fill = (x: string) => x.replace(/\{\{brand\}\}/g, 'CarmaCars').replace(/\{\{city\}\}/g, 'Toronto');
  const titles: string[] = [], descs: string[] = [];
  for (const t of trims) {
    titles.push(fit(titleOptions(t), fill, 70)); descs.push(fit(descriptionOptions({ ...t, cars: 0 }), fill, 170, 70));
    titles.push(fit(buyTitleOptions(t), fill, 70)); descs.push(fit(buyDescriptionOptions({ ...t, forSale: 0, recalls: 2 }), fill, 170, 70));
    for (const colour of colours) {
      titles.push(fit(tierTitleOptions({ ...t, colour }), fill, 70)); descs.push(fit(tierDescriptionOptions({ ...t, colour, cars: 0 }), fill, 170, 70));
      titles.push(fit(buyTitleOptions({ ...t, colour }), fill, 70)); descs.push(fit(buyDescriptionOptions({ ...t, colour, forSale: 0 }), fill, 170, 70));
    }
    for (const city of cities) {
      titles.push(fit(tierTitleOptions({ ...t, city, home: 'Toronto' }), fill, 70)); descs.push(fit(tierDescriptionOptions({ ...t, city, cars: 1, km: 12.5 }), fill, 170, 70));
      titles.push(fit(buyTitleOptions({ ...t, city }), fill, 70)); descs.push(fit(buyDescriptionOptions({ ...t, city, forSale: 1 }), fill, 170, 70));
      for (const colour of colours) {
        titles.push(fit(tierTitleOptions({ ...t, city, colour }), fill, 70)); descs.push(fit(tierDescriptionOptions({ ...t, city, colour, cars: 0 }), fill, 170, 70));
        titles.push(fit(buyTitleOptions({ ...t, city, colour }), fill, 70)); descs.push(fit(buyDescriptionOptions({ ...t, city, colour, forSale: 0 }), fill, 170, 70));
      }
    }
  }
  assert.equal(new Set(titles).size, titles.length, 'titles unique');
  assert.equal(new Set(descs).size, descs.length, 'descriptions unique');
  assert.ok(titles.every((x) => !/[\u2014\u2013]/.test(x)) && descs.every((x) => !/[\u2014\u2013]/.test(x)), 'no long dash');
  assert.ok(descs.every((d) => d.length <= 170), 'descriptions fit');
  assert.ok(titles.filter((x) => x.length > 70).length <= 6, 'almost every title fits 70 characters (an exotic long trim name may not)');
  assert.equal(shortPlace('Toronto Pearson Airport (YYZ)'), 'Pearson (YYZ)');
  assert.equal(fit(tierTitleOptions({ make: 'Volkswagen', model: 'Jetta', year: 2020, trim: 'Sportline', city: 'Mississauga', colour: 'Black' }), fill, 70), 'Rent a black 2020 Volkswagen Jetta Sportline in Mississauga');
  assert.ok(!/an? Orange/.test(fit(buyDescriptionOptions({ make: 'VW', model: 'Golf', year: 2020, colour: 'Orange', forSale: 0 }), fill, 170, 70)), 'colour in lower case after "an"');
});

test('every figure: a row only when a source has it, conversions labelled, bodies by trim', () => {
  const v = (o: Partial<Variant> & { id: number }): Variant => ({ epa_model: 'Jetta', displ: 1.4, cyl: 4, turbo: true, super: false, drive: 'Front-Wheel Drive', trans: 'Automatic (S8)', fuel: 'gasoline', vclass: 'Compact Cars',
    l100_city: 7.9, l100_hwy: 5.8, l100_comb: 7, kwh100: null, ev_range_km: null, co2_g_km: 163, mpg_city: 30, mpg_hwy: 40, mpg_comb: 34, fuel_cost_usd: 1450, ...o });
  const rows = statRows(specs([v({ id: 1 })], S), S);
  const labels = rows.map((r) => r.label);
  assert.ok(labels.includes('MPG combined (US)') && labels.includes('MPG combined (Imperial)') && labels.includes('Fuel cost a year (EPA)'));
  assert.ok(!labels.includes('Battery') && !labels.includes('Charge at 240 V') && !labels.includes('Luggage volume'), 'no source, no row');
  assert.equal(rows.find((r) => r.label === 'MPG combined (Imperial)')?.note, 'converted from the US figure');
  assert.equal(mpgImperial(34), 41);
  const dims = [{ body: 'JETTA 4DR SEDAN', length_cm: 470, width_cm: 180, height_cm: 146, wheelbase_cm: 269, curb_kg: 1350 }, { body: 'JETTA GLI 4DR SEDAN', length_cm: 471, width_cm: 180, height_cm: 145, wheelbase_cm: 269, curb_kg: 1450 }];
  assert.deepEqual(dimsFor(dims, 'Jetta', 'GLI').map((d) => d.body), ['JETTA GLI 4DR SEDAN']);
  assert.deepEqual(dimsFor(dims, 'Jetta', 'Highline').map((d) => d.body), ['JETTA 4DR SEDAN']);
  assert.deepEqual(dimsFor([], 'Jetta', 'GLI'), []);
});

test('0123: a vehicle page of the mechanical work we arrange says a trusted shop does it, never CarmaCars, with a rental meanwhile', () => {
  const o = { make: 'Honda', model: 'Civic', year: 2019, trim: 'LX', mode: 'bodyshop' as const, term: { slug: 'oil-change', name: 'Oil change', lead: 'auto_service' } };
  const d = termDescriptionOptions(o);
  assert.match(d[0]!, /^Oil change for a 2019 Honda Civic LX: we arrange it with a trusted shop, and rent you a car while yours is in\.$/);
  for (const x of d) { assert.doesNotMatch(x, /insurance|we (do|change|repair|fix)\b/i); assert.ok(x.length <= 170, x); }
  const body = termDescriptionOptions({ ...o, term: { slug: 'collision-repair', name: 'Collision repair', lead: 'bodyshop' } });
  assert.match(body[0]!, /insurance replacement rental/);
});
