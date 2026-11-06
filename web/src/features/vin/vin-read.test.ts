// VIN by photo or camera (release 28): the barcode's text and the read text made into one VIN.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bestVin, fixVin, readMessage, vinsFromModel, vinsIn } from './vin-read.ts';
import { vinCheckOk } from './vin.ts';

const GOOD = '1HGCM82633A004352';   // a published example: the check digit (3) adds up

test('a clean VIN is kept as read', () => {
  assert.deepEqual(fixVin(GOOD), { vin: GOOD, checkOk: true, corrected: false, raw: GOOD });
  assert.deepEqual(fixVin(' 1hgcm8-2633a 004352 '), { vin: GOOD, checkOk: true, corrected: false, raw: GOOD });
});

test('I, O and Q (never in a VIN) become 1, 0 and 0', () => {
  const r = fixVin('IHGCM82633AOO4352')!;
  assert.equal(r.vin, GOOD);
  assert.equal(r.corrected, true);
  assert.equal(r.checkOk, true);
  assert.equal(fixVin('1HGCM82633AQ04352')!.vin, GOOD);
});

test('one look-alike is swapped only when that makes the check digit add up', () => {
  // the 5 of a real VIN read as S: the swap back is the one change that adds up
  const vin = 'WP1AB2A56GLB12345';
  assert.equal(vinCheckOk(vin), true);
  const r = fixVin('WP1AB2A56GLB1234S')!;
  assert.equal(r.vin, vin);
  assert.equal(r.corrected, true);
  assert.equal(r.checkOk, true);
  // B read as 8 in the middle: more than one swap could add up, so nothing is changed and the read is flagged (never a
  // wrong "corrected" VIN)
  const r2 = fixVin('WP1A82A56GLB12345')!;
  assert.ok(r2.vin === vin || (!r2.checkOk && r2.vin === 'WP1A82A56GLB12345'));
});

test('a VIN that does not add up and has no single fix is returned unchanged, flagged', () => {
  const r = fixVin('WP1AB2A57GLB12345')!;
  assert.equal(r.checkOk, false);
  assert.equal(r.vin, 'WP1AB2A57GLB12345');
  assert.equal(fixVin('WP1AB2A56GLB1234'), null, '16 characters');
  assert.equal(fixVin(''), null);
});

test('the barcode: the "I" of an import before the VIN, and text around it', () => {
  assert.equal(bestVin('I' + GOOD)!.vin, GOOD);
  assert.equal(bestVin(`VIN: ${GOOD} MFD 03/03`)!.vin, GOOD);
  assert.equal(bestVin('1HGCM 82633 A004352')!.vin, GOOD, 'spaces between groups');
  assert.equal(bestVin('no vin here'), null);
  assert.equal(bestVin('X' + GOOD + 'Y')!.vin, GOOD, 'a longer run: the window that adds up');
});

test('several candidates: the ones that add up first', () => {
  const list = vinsIn(`WP1AB2A57GLB12345 ${GOOD}`);
  assert.equal(list[0]!.vin, GOOD);
  assert.ok(list.every((x) => x.checkOk));
});

test('the vision model answer: the vin field first, then the others', () => {
  assert.equal(vinsFromModel({ vin: 'IHGCM82633AOO4352', other: [] })[0]!.vin, GOOD);
  assert.equal(vinsFromModel({ vin: '', other: [GOOD] })[0]!.vin, GOOD);
  assert.deepEqual(vinsFromModel({ vin: 'none' }), []);
  assert.deepEqual(vinsFromModel(null), []);
});

test('what the person is told', () => {
  assert.match(readMessage(fixVin(GOOD)!, 'barcode'), /Read from the barcode/);
  assert.match(readMessage(fixVin('IHGCM82633AOO4352')!, 'photo'), /misread character corrected/);
  assert.match(readMessage(fixVin('WP1AB2A57GLB12345')!, 'photo'), /does not add up/);
});
