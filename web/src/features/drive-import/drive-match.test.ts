import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isCarFolder, makeHit, matchFolder, modelHit, norm, plateKey, platesIn, scoreCar, yearsIn, type Car } from './drive-match.ts';

// Made-up cars and plates (example only).
const cars: Car[] = [
  { id: 'c1', year: 2022, make: 'Mercedes-Benz', model: 'C-Class', trim: 'C 300', colour: 'White', plate: 'CABC 123', partner: null },
  { id: 'c2', year: 2023, make: 'Mercedes-Benz', model: 'GLE-Class', trim: 'GLE 350', colour: 'Black', plate: 'CXYZ 987', partner: null },
  { id: 'c3', year: 2021, make: 'Toyota', model: 'Camry', colour: 'Silver', plate: null, partner: '01 Motors' },
  { id: 'c4', year: 2021, make: 'Toyota', model: 'Camry', colour: 'Silver', plate: 'BTLR 456', partner: null },
  { id: 'c5', year: 2020, make: 'Honda', model: 'Civic', colour: 'Blue', plate: 'DEFG 321', partner: null }
];

test('norm, plateKey, yearsIn, platesIn', () => {
  assert.equal(norm('  Citroën  C4-Picasso!! '), 'citroen c4 picasso');
  assert.equal(plateKey('cabc 123'), 'CABC123');
  assert.deepEqual(yearsIn('2022 C300 (2019 photos) 12022 3000'), [2022, 2019]);
  assert.ok(platesIn('GLE 350 - CXYZ 987 white').includes('CXYZ987'));
  assert.ok(platesIn('car abcd-123').includes('ABCD123'));
  assert.ok(!platesIn('2022 camry').includes('2022'));
});

test('modelHit: spaces, dashes and the class word do not matter', () => {
  assert.equal(modelHit('2022 Mercedes C300 white', 'C-Class', 'C 300'), 1);
  assert.equal(modelHit('c 300', 'C-Class', 'C 300'), 1);
  assert.equal(modelHit('GLE350 4matic', 'GLE-Class', 'GLE 350'), 1);
  assert.equal(modelHit('Toyota Camry SE', 'Camry'), 1);
  assert.equal(modelHit('Honda Accord', 'Civic'), 0);
  assert.equal(makeHit('Mercedes C300', 'Mercedes-Benz'), true);
  assert.equal(makeHit('VW Golf', 'Volkswagen'), true);
  assert.equal(makeHit('Toyota', 'Honda'), false);
});

test('a plate in the folder name settles it', () => {
  const m = matchFolder('GLE 350 CXYZ 987', ['Mercedes'], cars);
  assert.equal(m.vehicle_id, 'c2');
  assert.ok(m.candidates[0]!.why.includes('plate'));
  assert.equal(m.ambiguous, false);
});

test('year, make, model and colour, with the make from the folder above', () => {
  const m = matchFolder('2022 C300 white', ['Photos', 'Mercedes-Benz'], cars);
  assert.equal(m.vehicle_id, 'c1');
  assert.deepEqual(m.candidates[0]!.why.sort(), ['colour', 'make', 'model', 'year']);
  assert.match(m.note, /matched on/);
});

test('the wrong year or colour counts against a car', () => {
  const right = scoreCar('2021 Honda Civic blue', [], cars[4]!);
  const wrong = scoreCar('2018 Honda Civic red', [], cars[4]!);
  assert.ok(right.score > wrong.score);
  assert.ok(wrong.why.includes('another year') && wrong.why.includes('another colour'));
});

test('two alike cars: 01 Motors partner cars first, and the match is flagged for a look', () => {
  const m = matchFolder('2021 Toyota Camry silver', ['Toyota'], cars);
  assert.equal(m.vehicle_id, 'c3');
  assert.equal(m.ambiguous, true);
  assert.deepEqual(m.candidates.slice(0, 2).map((c) => c.vehicle_id), ['c3', 'c4']);
  // the plate picks the other one
  assert.equal(matchFolder('2021 Toyota Camry BTLR456', ['Toyota'], cars).vehicle_id, 'c4');
});

test('a make folder alone is not a car, and a folder that looks like nothing is not matched', () => {
  const m = matchFolder('Mercedes', [], cars);
  assert.equal(m.vehicle_id, null);
  assert.equal(matchFolder('Interior extras', [], cars).vehicle_id, null);
  assert.equal(matchFolder('Interior extras', [], cars).candidates.length, 0);
  assert.equal(matchFolder('2022 Ferrari Roma', ['Ferrari'], cars).vehicle_id, null);
});

test('a car already taken by another folder ranks lower', () => {
  const a = matchFolder('2021 Toyota Camry silver', [], [cars[2]!, cars[3]!], { taken: new Set(['c3']) });
  assert.equal(a.vehicle_id, 'c4');
});

test('isCarFolder: photos of its own', () => {
  assert.equal(isCarFolder(0), false);
  assert.equal(isCarFolder(12), true);
});
