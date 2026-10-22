// VIN-first entry (migration 0082): the check digit, the decoder's answer in our words, the summary line, the colour,
// and what the form sends.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { COLOURS, carName, chooseGearbox, epaGearbox, gearboxOf, trimCandidates, cleanVin, colourFromAnswer, colourName, detailLine, expectedCheckDigit, fuelOf, makeName, mapVpic, trimOf, vinCheckOk, vinMessage, vinState, yearChoices } from './vin.ts';
import { effectiveCar, emptyVin, vinPayload, vinProblem, type VinValue } from './entry.ts';

test('the check digit (position 9) of real VINs', () => {
  // published examples: a 2003 Honda Accord, and the VINs of the fake decoder
  assert.equal(expectedCheckDigit('1HGCM82633A004352'), '3');
  assert.equal(vinCheckOk('1HGCM82633A004352'), true);
  for (const v of ['WP1AB2A56GLB12345', '1G6AX5SX5F0123456', '1FM5K8D87LGA12345', '2HGFC2F59KH123456', 'WDDZF4KBXHA123456']) assert.equal(vinCheckOk(v), true, v);
  assert.equal(expectedCheckDigit('WDDZF4KB0HA123456'), 'X', 'a remainder of 10 is X');
  assert.equal(vinCheckOk('WP1AB2A57GLB12345'), false, 'one digit off');
  assert.equal(expectedCheckDigit('WP1AB2A56GLB1234'), null, '16 characters');
});

test('the VIN as people type it: spaces, dashes and lower case are fine', () => {
  assert.equal(cleanVin(' wp1ab2a5-6glb 12345 '), 'WP1AB2A56GLB12345');
  assert.deepEqual(vinState('wp1ab2a56glb12345'), { kind: 'ok', vin: 'WP1AB2A56GLB12345' });
});

test('what the VIN field says while typing, in plain words', () => {
  assert.equal(vinMessage(vinState('')), null);
  assert.equal(vinMessage(vinState('WP1AB2')), '6 of 17 characters');
  assert.match(vinMessage(vinState('WP1AB2A56GLB1234O'))!, /O is probably 0/);
  assert.match(vinMessage(vinState('WP1AB2A56GLB12345X'))!, /has 18/);
  assert.match(vinMessage(vinState('WP1AB2A5#GLB12345'))!, /remove "#"/);
  const s = vinState('WP1AB2A57GLB12345');
  assert.equal(s.kind, 'check_digit');
  assert.match(vinMessage(s)!, /does not add up.*You can still save it/);
  assert.equal(vinMessage(vinState('WP1AB2A56GLB12345')), null);
});

test('vPIC answers in the listing worker\'s shape', () => {
  const d = mapVpic({
    ModelYear: '2016', Make: 'PORSCHE', Model: 'Macan', Trim: 'S', Series: '', BodyClass: 'Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)',
    FuelTypePrimary: 'Gasoline', ElectrificationLevel: '', DriveType: 'AWD/All-Wheel Drive', TransmissionStyle: 'Automatic', TransmissionSpeeds: '7',
    Doors: '5', Seats: '5', DisplacementL: '3.0', EngineCylinders: '6', EngineConfiguration: 'V-Shaped', Turbo: 'Yes', ErrorCode: '0'
  });
  assert.equal(d.ok, true);
  assert.deepEqual([d.year, d.make, d.model, d.trim, d.fuel, d.drivetrain, d.transmission, d.doors, d.seats, d.engine], ['2016', 'Porsche', 'Macan', 'S', 'gasoline', 'AWD/All-Wheel Drive', 'Automatic, 7 speeds', '5', '5', '3.0 L, V6, turbo']);
  const cvt = mapVpic({ ModelYear: '2022', Make: 'CHEVROLET', Model: 'Malibu', Trim: 'LS', TransmissionStyle: 'Continuously Variable Transmission (CVT)', TransmissionSpeeds: '1', DisplacementL: '1.5', EngineCylinders: '4' });
  assert.equal(cvt.transmission, 'Continuously Variable Transmission (CVT)', 'no speeds for a CVT');
  assert.equal(cvt.engine, '1.5 L, 4 cylinders');
  assert.equal(mapVpic({ ModelYear: '', Make: '', Model: '', ErrorCode: '11' }).ok, false, 'no year, make and model: not decoded');
  assert.equal(mapVpic({ ModelYear: '2019', Make: 'VOLKSWAGEN', Model: 'Beetle', Trim: 'S, Final Edition SE, SE' }).trim, '', 'a list of trims is no trim');
  assert.equal(mapVpic({ ModelYear: '2020', Make: 'FORD', Model: 'Explorer', Trim: '', Series: 'XLT', Seats: 'Not Applicable' }).trim, 'XLT', 'the series when there is no trim');
});

test('makes, trims and fuel in our words', () => {
  assert.equal(makeName('MERCEDES-BENZ'), 'Mercedes-Benz');
  assert.equal(makeName('BMW'), 'BMW');
  assert.equal(makeName('LAND ROVER'), 'Land Rover');
  assert.equal(makeName('VOLKSWAGEN'), 'Volkswagen');
  assert.equal(trimOf('S / SE / R-Line'), '');
  assert.equal(trimOf('EX-L'), 'EX-L');
  assert.equal(fuelOf('Gasoline', 'Strong HEV (Hybrid Electric Vehicle)'), 'hybrid');
  assert.equal(fuelOf('Electric', 'PHEV (Plug-in Hybrid Electric Vehicle)'), 'plug_in_hybrid');
  assert.equal(fuelOf('Electric', 'BEV (Battery Electric Vehicle)'), 'electric');
  assert.equal(fuelOf('Flexible Fuel Vehicle (FFV)', ''), 'gasoline');
  assert.equal(fuelOf('Diesel', ''), 'diesel');
});

test('the summary line', () => {
  const c = { year: 2016, make: 'Porsche', model: 'Macan', trim: 'S', body: 'SUV', seats: 5, doors: 5, fuel: 'gasoline', drivetrain: 'All-wheel drive', transmission: 'Automatic', engine: '3.0 L, V6, turbo' };
  assert.equal(carName(c), '2016 Porsche Macan S');
  assert.equal(detailLine(c), 'SUV · 5 seats · 5 doors · Gas · All-wheel drive · Automatic · 3.0 L, V6, turbo');
  assert.equal(detailLine({ body: 'Sedan', fuel: 'electric' }), 'Sedan · Electric');
});

test('the colour: a swatch from any wording, the vision model\'s answer only when sure', () => {
  assert.equal(COLOURS.length, 13);
  assert.equal(colourName('BLACK'), 'Black');
  assert.equal(colourName('Gunmetal Grey Metallic'), 'Grey');
  assert.equal(colourName('Alpine White'), 'White');
  assert.equal(colourName('Sapphire'), 'Blue');
  assert.equal(colourName('chartreuse'), null);
  assert.equal(colourFromAnswer({ colour: 'silver', confidence: 90 }), 'Silver');
  assert.equal(colourFromAnswer({ color: 'Red' }), 'Red', 'no confidence given: taken');
  assert.equal(colourFromAnswer({ colour: 'Red', confidence: 40 }), null, 'unsure: left empty');
  assert.equal(colourFromAnswer('Red'), null);
});

test('the year list runs from next year back to 1990', () => {
  const y = yearChoices(new Date('2026-10-21T12:00:00Z'));
  assert.equal(y[0], 2027);
  assert.equal(y[y.length - 1], 1990);
});

const decodedValue = (): VinValue => ({
  ...emptyVin(), vin: 'WP1AB2A56GLB12345', class: 'premium', classWhy: 'Premium: a Porsche',
  facts: { vin: 'WP1AB2A56GLB12345', valid: true, check_ok: true, taken: null, class: { class: 'premium', why: 'Premium: a Porsche', rule: null }, rates: null,
    decode: { year: 2016, make: 'Porsche', model: 'Macan', trim: 'S', body: 'SUV', fuel: 'gasoline', drivetrain: 'All-wheel drive', transmission: 'Automatic', doors: 5, seats: 5, engine: '3.0 L' } }
});

test('what the form sends: only the VIN and what a person changed (the database fills the rest from the decode)', () => {
  const v = decodedValue();
  assert.equal(vinProblem(v), null);
  assert.deepEqual(vinPayload(v), { class: 'premium', class_source: 'inferred', colour: undefined, vin: 'WP1AB2A56GLB12345' });
  const edited = { ...v, edits: { trim: 'GTS', year: '2016' }, colour: 'Blue', classSource: 'person' as const, class: 'luxury' };
  assert.deepEqual(vinPayload(edited), { class: 'luxury', class_source: 'person', colour: 'Blue', vin: 'WP1AB2A56GLB12345', trim: 'GTS' }, 'an unchanged year is not sent');
  assert.equal(effectiveCar(edited).trim, 'GTS');
});

test('no decode, or a plate: year, make and model are asked and sent, never more', () => {
  const failed: VinValue = { ...emptyVin(), vin: 'ZZZZZ12370A123456', facts: { vin: 'ZZZZZ12370A123456', valid: true, check_ok: true, decode: null, taken: null, class: null, rates: null } };
  assert.equal(vinProblem(failed), 'Choose the year, make and model.');
  const filled = { ...failed, edits: { year: '2019', make: 'Toyota', model: 'Corolla' } };
  assert.equal(vinProblem(filled), null);
  assert.deepEqual(vinPayload(filled), { class: 'standard', class_source: 'inferred', colour: undefined, vin: 'ZZZZZ12370A123456', year: 2019, make: 'Toyota', model: 'Corolla' });
  const plate: VinValue = { ...emptyVin(), mode: 'plate', plate: 'abcd 123', edits: { year: '2021', make: 'Ford', model: 'Mustang' } };
  assert.equal(vinProblem(plate), null);
  assert.equal(vinPayload(plate).plate, 'ABCD123');
  assert.equal(vinPayload(plate).vin, undefined);
  assert.equal(vinProblem({ ...emptyVin(), vin: 'WP1AB2' }), 'Enter the 17-character VIN, or add the car by its plate.');
  assert.equal(vinProblem({ ...emptyVin(), vin: 'WP1AB2A56GLB12345' }), 'Wait for the VIN to be looked up.');
  assert.equal(vinProblem({ ...emptyVin(), mode: 'plate', plate: '' }), 'Enter the plate.');
});

test('0094: a list of trims is no trim, and its candidates are kept in order', () => {
  assert.equal(trimOf('FE or LXS'), '');
  assert.deepEqual(trimCandidates('S, Final Edition SE, Final Edition SEL, SE'), ['S', 'Final Edition SE', 'Final Edition SEL', 'SE']);
  assert.deepEqual(trimCandidates('S / SE / R-Line'), ['S', 'SE', 'R-Line']);
  assert.deepEqual(trimCandidates('FE, LXS'), ['FE', 'LXS']);
  assert.equal(trimCandidates('EX-L'), null);
  assert.equal(trimCandidates('Sport'), null);
  const m = mapVpic({ ModelYear: '2021', Make: 'KIA', Model: 'Forte', Trim: 'FE, LXS' });
  assert.equal(m.trim, '');
  assert.deepEqual(m.trim_candidates, ['FE', 'LXS']);
});

test('0094: the gearbox from EPA when one type covers every row; vPIC only when explicit; else none', () => {
  assert.equal(gearboxOf('Manual/Standard'), 'Manual');
  assert.equal(gearboxOf('Automated Manual Transmission (AMT)'), 'Automatic (dual-clutch)');
  assert.equal(gearboxOf('Continuously Variable Transmission (CVT)'), 'Automatic (CVT)');
  assert.equal(epaGearbox(['Auto (S6), 4 cyl, 2.0 L, Turbo', 'Auto (S6), 4 cyl, 1.4 L, Turbo']), 'Automatic');
  assert.equal(epaGearbox(['Auto (AV-S7), 4 cyl, 2.0 L', 'Auto(AV), 4 cyl, 2.0 L']), 'Automatic (CVT)');
  assert.equal(epaGearbox(['Auto (AM-S7), 6 cyl, 3.0 L, Turbo']), 'Automatic (dual-clutch)');
  assert.equal(epaGearbox(['Auto (S6), 4 cyl', 'Man 6-spd, 4 cyl']), 'mixed');
  assert.equal(epaGearbox([]), null);
  // the Beetle: vPIC said Manual by default, EPA says automatic only
  assert.deepEqual(chooseGearbox('Automatic', { style: 'Manual/Standard', speeds: '' }), { gearbox: 'Automatic', source: 'epa' });
  assert.deepEqual(chooseGearbox('Automatic', { style: 'Manual/Standard', speeds: '6' }), { gearbox: null, source: 'none' });
  assert.deepEqual(chooseGearbox('mixed', { style: 'Automatic', speeds: '6' }), { gearbox: null, source: 'none' });
  assert.deepEqual(chooseGearbox(null, { style: 'Manual/Standard', speeds: '' }), { gearbox: null, source: 'none' });
  assert.deepEqual(chooseGearbox(null, { style: 'Automatic', speeds: '8' }), { gearbox: 'Automatic', source: 'vpic_explicit' });
});
