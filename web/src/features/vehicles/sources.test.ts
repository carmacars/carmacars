// The further catalog sources (0115): the vPIC database export, NRCan's Fuel Consumption Ratings and Wikidata's older
// models, read into the catalog by buildCatalog's `extra` (web/scripts/catalog/import.mjs --vpic-export, --nrcan, --wikidata).
//   node --test --experimental-strip-types src/features/vehicles/sources.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildCatalog, cleanModelName, csvRows, nrcanTrans, parseCsv, parseNrcanCsv, parseVpicExport, parseWikidata, splitTrims } from './normalise.ts';
import { specs } from './content.ts';

const epa = (o: Record<string, string>) => ({ id: '1', year: '2022', make: 'GMC', model: 'Sierra 4WD', baseModel: 'Sierra', fuelType: 'Regular', atvType: '', displ: '5.3', cylinders: '8',
  drive: '4-Wheel Drive', trany: 'Automatic (S10)', VClass: 'Standard Pickup Trucks 4WD', city08: '16', highway08: '20', comb08: '17', ...o });

test('CSV: a byte-order mark is dropped, quoted commas kept, rows as cells', () => {
  assert.deepEqual(csvRows('﻿a,b\n"x, y",2\r\n'), [['a', 'b'], ['x, y', '2']]);
  assert.deepEqual(parseCsv('﻿make,model\nGMC,Sierra\n'), [{ make: 'GMC', model: 'Sierra' }]);
});

test('model names from other sources lose drive, body and fuel-system words; trims split and cleaned', () => {
  assert.equal(cleanModelName('F-150 FFV 4X4'), 'F-150');
  assert.equal(cleanModelName('Civic Sedan'), 'Civic');
  assert.equal(cleanModelName('MDX SH-AWD'), 'MDX');
  assert.equal(cleanModelName('Sierra 4WD AT4'), 'Sierra AT4');
  assert.equal(cleanModelName('Cab'), 'Cab', 'a name that is only such words is kept');
  assert.deepEqual(splitTrims('LX; EX / EX-L, Sport,  sport ', 'Civic'), ['LX', 'EX', 'EX-L', 'Sport']);
  assert.deepEqual(splitTrims('N/A', 'Civic'), []);
  assert.deepEqual(splitTrims('Civic', 'Civic'), [], 'the model name is not a trim');
  assert.deepEqual(splitTrims('x'.repeat(41), 'Civic'), [], 'too long for a trim');
});

test('vPIC export: the types asked for, with trims and a class for trucks, buses and motorcycles', () => {
  const csv = 'make,model,year,vehicle_type,trim\nFreightliner,Cascadia,2024,Truck,\nHonda,Civic,2024,Passenger Car,LX; Sport\nHarley-Davidson,Street Glide,2024,Motorcycle,Special\n';
  const rows = parseVpicExport(csv);
  assert.deepEqual(rows.map((r) => r.model), ['Cascadia', 'Civic'], 'motorcycles only when asked');
  assert.equal(rows[0]!.vclass, 'Truck');
  assert.equal(parseVpicExport(csv, new Set(['motorcycle']))[0]!.vclass, 'Motorcycle');
  const tsv = 'make\tmodel\tyear\tvehicle_type\ttrim\n----\t-----\t----\t------------\t----\nHonda\tCivic\t2024\tPassenger Car\tNULL\nGMC\tSierra\t2024\tTruck\tAT4\n';
  assert.deepEqual(parseVpicExport(tsv).map((r) => [r.model, r.trim]), [['Civic', null], ['Sierra', 'AT4']], 'sqlcmd text: tabs, the dashes line and NULL');
});

test('NRCan: both header layouts, the gearbox codes, EV and plug-in hybrid lists', () => {
  assert.equal(nrcanTrans('AS8'), 'Automatic (S8)');
  assert.equal(nrcanTrans('AV'), 'Automatic (variable gear ratios)');
  assert.equal(nrcanTrans('M6'), 'Manual 6-spd');
  assert.equal(nrcanTrans('AM7'), 'Automatic (AM7)');
  assert.equal(nrcanTrans('A4'), 'Automatic 4-spd');
  assert.equal(nrcanTrans('?'), null);
  const old = 'MODEL,MAKE,MODEL,VEHICLE CLASS,ENGINE SIZE,CYLINDERS,TRANSMISSION,FUEL,FUEL CONSUMPTION,,,,CO2 EMISSIONS ,CO2,SMOG\n'
    + 'YEAR,,,,(L),,,TYPE,CITY (L/100 km),HWY (L/100 km),COMB (L/100 km),COMB (mpg),(g/km),RATING,RATING\n'
    + '2012,CHEVROLET,ORLANDO,STATION WAGON - MID-SIZE,2.4,4,AS6,X,10.6,7.2,9.1,31,209,,\n';
  const a = parseNrcanCsv(old);
  assert.equal(a.length, 1);
  assert.deepEqual([a[0]!.make, a[0]!.model, a[0]!.year], ['CHEVROLET', 'ORLANDO', 2012]);
  assert.deepEqual([a[0]!.variant!.l100_city, a[0]!.variant!.l100_hwy, a[0]!.variant!.l100_comb, a[0]!.variant!.co2_g_km, a[0]!.variant!.trans, a[0]!.variant!.src],
    [10.6, 7.2, 9.1, 209, 'Automatic (S6)', 'nrcan']);
  const now = 'Model year,Make,Model,Vehicle class,Engine size (L),Cylinders,Transmission,Fuel type,City (L/100 km),Highway (L/100 km),Combined (L/100 km),Combined (mpg),CO2 emissions (g/km),CO2 rating,Smog rating\n'
    + '2024,GMC,Sierra 4WD AT4,Pickup truck: Standard,6.2,8,A10,Z,16.4,12.6,14.7,19,345,3,3\n';
  const b = parseNrcanCsv(now)[0]!;
  assert.deepEqual([b.variant!.fuel, b.variant!.drive, b.variant!.l100_comb, b.variant!.displ], ['premium', '4-Wheel Drive', 14.7, 6.2]);
  const bev = 'Model year,Make,Model,Vehicle class,Motor (kW),Transmission,Fuel type,City (kWh/100 km),Highway (kWh/100 km),Combined (kWh/100 km),City (Le/100 km),Highway (Le/100 km),Combined (Le/100 km),Range (km),CO2 emissions (g/km),CO2 rating,Smog rating,Recharge time (h)\n'
    + '2024,Hyundai,Kona Electric,SUV: Small,150,A1,B,15.9,19.3,17.4,1.8,2.2,2.0,420,0,10,,9\n';
  const e = parseNrcanCsv(bev)[0]!.variant!;
  assert.deepEqual([e.fuel, e.kwh100, e.ev_range_km, e.l100_comb, e.co2_g_km], ['electric', 17.4, 420, null, 0]);
  const phev = 'Model year,Make,Model,Vehicle class,Motor (kW),Engine size (L),Cylinders,Transmission,Fuel type 1,City (kWh/100 km),Highway (kWh/100 km),Combined (kWh/100 km),City (Le/100 km),Highway (Le/100 km),Combined Le/100 km,Range 1 (km),Recharge time (h),Fuel type 2,City (L/100 km),Highway (L/100 km),Combined (L/100 km),Range 2 (km),CO2 emissions (g/km),CO2 rating,Smog rating\n'
    + '2024,Toyota,RAV4 Prime AWD,SUV: Small,134,2.5,4,AV,B,23.2,26.6,24.7,2.6,3.0,2.8,68,4.5,X,5.9,6.8,6.3,940,61,10,7\n';
  const p = parseNrcanCsv(phev)[0]!;
  assert.deepEqual([p.variant!.fuel, p.variant!.ev_range_km, p.variant!.l100_comb, p.variant!.drive, p.variant!.displ], ['plug_in_hybrid', 68, 6.3, 'All-Wheel Drive', 2.5]);
  assert.deepEqual(parseNrcanCsv('a,b\n1,2\n'), [], 'a file that is not a ratings list gives nothing');
});

test('Wikidata: makes without the company words, years before 1981 only, twenty years at most', () => {
  const j = { results: { bindings: [
    { makeLabel: { value: 'Ford Motor Company' }, modelLabel: { value: 'Ford Model T' }, start: { value: '1908-01-01T00:00:00Z' }, end: { value: '1927-01-01T00:00:00Z' } },
    { makeLabel: { value: 'Studebaker' }, modelLabel: { value: 'Avanti' }, start: { value: '1962-01-01T00:00:00Z' } },
    { makeLabel: { value: 'Ford' }, modelLabel: { value: 'Focus' }, start: { value: '1998-01-01T00:00:00Z' } },
    { makeLabel: { value: 'Ford' }, modelLabel: { value: 'Q123' }, start: { value: '1950-01-01T00:00:00Z' } }] } };
  const rows = parseWikidata(j);
  assert.equal(rows.filter((r) => r.model === 'Model T').length, 20);
  assert.ok(rows.every((r) => r.make !== 'Ford Motor Company'));
  assert.deepEqual(rows.filter((r) => r.make === 'Studebaker').map((r) => r.year), [1962], 'no end year: the first year only');
  assert.ok(!rows.some((r) => r.model === 'Focus' || r.model === 'Q123'));
});

test('buildCatalog with further sources: new makes only when allowed, models by name or prefix, trims, NRCan figures only without EPA', () => {
  const rows = [epa({}), epa({ id: '2', year: '2023' })];
  const c = buildCatalog(rows, {
    years: [1981, 2027],
    trimLines: [{ make: 'gmc', model: 'Sierra', from: 2023, to: 2023, trims: ['Pro', 'SLE'] }],
    extra: [
      { source: 'vpicdb', newMakes: true, years: [1981, 2027], rows: [
        { make: 'GMC', model: 'Sierra', year: 2022, trim: 'Pro; SLE; AT4' }, { make: 'GMC', model: 'Sierra', year: 2023, trim: 'Denali' },
        { make: 'GMC', model: 'Sierra', year: 2024, trim: 'Pro; SLE; AT4' }, { make: 'GMC', model: 'Sierra', year: 2025, trim: 'Pro; SLE; AT4' },
        { make: 'Freightliner', model: 'Cascadia', year: 2024, vclass: 'Truck' }] },
      { source: 'nrcan', newMakes: false, years: [1995, 2027], rows: [
        ...parseNrcanCsv('Model year,Make,Model,Vehicle class,Engine size (L),Cylinders,Transmission,Fuel type,City (L/100 km),Highway (L/100 km),Combined (L/100 km),CO2 emissions (g/km)\n'
          + '2022,GMC,Sierra 4WD AT4,Pickup truck: Standard,6.2,8,A10,Z,16.4,12.6,14.7,345\n2024,GMC,Sierra 4WD AT4,Pickup truck: Standard,6.2,8,A10,Z,16.4,12.6,14.7,345\n'
          + '2024,Lada,Niva,SUV: Small,1.7,4,M5,X,11,9,10,230\n')] },
      { source: 'wikidata', newMakes: false, years: [1900, 1980], rows: [{ make: 'GMC', model: 'Sierra', year: 1975 }, { make: 'Studebaker', model: 'Avanti', year: 1963 }] }
    ]
  });
  assert.deepEqual(c.makes.map((m) => m.slug), ['freightliner', 'gmc'], 'a vPIC-only make when allowed; NRCan and Wikidata add none here');
  assert.deepEqual(c.models.map((m) => m.slug).sort(), ['cascadia', 'sierra'], 'NRCan "Sierra 4WD AT4" is the Sierra, no second model');
  const sierra = c.models.find((m) => m.slug === 'sierra')!;
  assert.deepEqual(sierra.sources, ['epa', 'nrcan', 'vpicdb', 'wikidata']);
  const yrs = c.years.filter((y) => y.model === 'sierra');
  assert.deepEqual(yrs.map((y) => y.year), [1975, 2022, 2023, 2024, 2025]);
  assert.ok(yrs.find((y) => y.year === 2022)!.variants.every((v) => !v.src), 'EPA has 2022: NRCan figures not added');
  assert.deepEqual(yrs.find((y) => y.year === 2024)!.variants.map((v) => v.src), ['nrcan'], 'no EPA row for 2024: the Canadian figures');
  assert.equal(specs(yrs.find((y) => y.year === 2024)!.variants, { gas_cents: 155, premium_extra_cents: 20, elec_cents: 15 })[0]!.src, 'nrcan', 'the powertrain says its source');
  const lines = c.trim_lines.filter((t) => t.model === 'sierra');
  assert.deepEqual(lines.map((t) => [t.from, t.to, t.trims.join('|')]), [[2023, 2023, 'Pro|SLE'], [2022, 2022, 'Pro|SLE|AT4'], [2024, 2025, 'Pro|SLE|AT4']],
    'the curated line wins for 2023; runs of the same names become one line');
});
