// The licence reader's pure parts (release 31, D2): AAMVA barcode text from sample licences (made up: fake people, fake
// numbers), the Ontario number check, the vision model's answer, the retake message.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aamvaDate, fieldsFromModel, isOntario, ontarioCheck, ontarioFormat, parseAamva, retakeMessage } from './aamva.ts';

// an Ontario card (AAMVA version 9, Canadian dates CCYYMMDD); every value is invented
const ONTARIO = '@\n\u001e\rANSI 636012090002DL00410290ZO03310008DLDAQD1234-56789-90125\nDCSDRIVER\nDACRILEY\nDADJAMES\nDBB19901225\nDBD20220301\nDBA20271225\nDCAG\nDAG100 EXAMPLE ST\nDAITORONTO\nDAJON\nDAKM5V 0A1\nDCGCAN\nDBC1\r';
// a US card (MMDDCCYY), the name in the newer elements
const NEWYORK = '@\n\u001e\rANSI 636001080102DL00410288ZN03290015DLDAQ123456789\nDCSSAMPLE\nDACALEX\nDADNONE\nDBB07041988\nDBD03012021\nDBA07042029\nDCAD\nDAG1 MAIN ST\nDAIALBANY\nDAJNY\nDAK122070000\nDCGUSA\r';
// an older card with the whole name in DAA and no country
const OLD = '@\n\u001e\rANSI 636017030002DL00290190DLDAAPERSON,CASEY,M\nDAQP1234-567890-12\nDBB19850315\nDBA20280315\nDAJQC\r';

test('AAMVA: an Ontario licence, Canadian dates, the address', () => {
  const f = parseAamva(ONTARIO)!;
  assert.equal(f.full_name, 'Riley James Driver');
  assert.equal(f.last_name, 'Driver');
  assert.equal(f.date_of_birth, '1990-12-25');
  assert.equal(f.licence_number, 'D1234-56789-90125');
  assert.equal(f.licence_class, 'G');
  assert.equal(f.issued_on, '2022-03-01');
  assert.equal(f.expires_on, '2027-12-25');
  assert.equal(f.issuer, 'ON');
  assert.equal(f.country, 'CAN');
  assert.equal(f.address, '100 Example St, Toronto, ON, M5V 0A1');
});

test('AAMVA: a US licence, US dates, "NONE" left out, the ZIP+4 shortened', () => {
  const f = parseAamva(NEWYORK)!;
  assert.equal(f.full_name, 'Alex Sample');
  assert.equal(f.date_of_birth, '1988-07-04');
  assert.equal(f.expires_on, '2029-07-04');
  assert.equal(f.issuer, 'NY');
  assert.equal(f.country, 'USA');
  assert.equal(f.address, '1 Main St, Albany, NY, 12207');
});

test('AAMVA: an older card, the name in DAA, the country from the province', () => {
  const f = parseAamva(OLD)!;
  assert.equal(f.last_name, 'Person');
  assert.equal(f.first_name, 'Casey');
  assert.equal(f.issuer, 'QC');
  assert.equal(f.country, 'CAN');
  assert.equal(f.date_of_birth, '1985-03-15');
});

test('AAMVA: not a licence, and dates that are not days', () => {
  assert.equal(parseAamva('https://example.test/a-qr-code'), null);
  assert.equal(parseAamva(''), null);
  assert.equal(aamvaDate('20231340'), null);
  assert.equal(aamvaDate('12252030', 'USA'), '2030-12-25');
  assert.equal(aamvaDate('20301225', 'CAN'), '2030-12-25');
});

test('Ontario: the format, the family name\'s letter, the date of birth in the last six digits (month + 50 too)', () => {
  assert.equal(ontarioFormat('d123456789 01225'), 'D1234-56789-01225');
  assert.equal(ontarioFormat('D1234-5678-01225'), null);
  assert.deepEqual(ontarioCheck('D1234-56789-01225', 'Driver', '1990-12-25'), { format: true, letter: true, birth: true });
  assert.deepEqual(ontarioCheck('D1234-56789-06225', 'Driver', '1990-12-25'), { format: true, letter: true, birth: true });
  assert.deepEqual(ontarioCheck('D1234-56789-01224', 'Driver', '1990-12-25'), { format: true, letter: true, birth: false });
  assert.deepEqual(ontarioCheck('S1234-56789-01225', 'Driver', '1990-12-25'), { format: true, letter: false, birth: true });
  assert.deepEqual(ontarioCheck('D1234-56789-901225', 'Driver', '1990-12-25'), { format: false, letter: null, birth: null });
  assert.ok(isOntario('ON') && isOntario('Ontario') && !isOntario('QC') && !isOntario(null));
});

test('the vision model\'s answer: only well-formed values; the quality and the side', () => {
  const r = fieldsFromModel({ side: 'front', quality: 'cut off', first_name: 'RILEY', last_name: 'DRIVER', date_of_birth: '1990-12-25', licence_number: 'd1234-5678-9901225',
    licence_class: 'g', issued_on: '2022-02-30', expires_on: '2027-12-25', issuer: 'Ontario', address: '100 Example St, Toronto' });
  assert.equal(r.quality, 'cut_off');
  assert.equal(r.side, 'front');
  assert.equal(r.fields.full_name, 'Riley Driver');
  assert.equal(r.fields.issued_on, null);
  assert.equal(r.fields.issuer, 'ON');
  assert.equal(r.fields.country, 'CAN');
  assert.equal(r.fields.licence_class, 'G');
  assert.equal(fieldsFromModel(null).quality, 'unreadable');
});

test('a photo that cannot be used: one plain message to take it again', () => {
  assert.match(retakeMessage('blurry', 'licence_front')!, /blurry\. Take it again/);
  assert.match(retakeMessage('cut_off', 'licence_back')!, /all four corners/);
  assert.equal(retakeMessage('ok', 'licence_front'), null);
});
