import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { nameCase } from './name-case.ts';

describe('make, model and trim in capitals become proper case (0087)', () => {
  it('the owner\'s Jetta', () => {
    assert.equal(nameCase('VOLKSWAGEN', 'make'), 'Volkswagen');
    assert.equal(nameCase('JETTA', 'model'), 'Jetta');
    assert.equal(nameCase('COMFORTLINE SPORT', 'trim'), 'Comfortline Sport');
  });
  it('brands, digits and acronyms', () => {
    assert.equal(nameCase('MERCEDES-BENZ', 'make'), 'Mercedes-Benz');
    assert.equal(nameCase('BMW', 'make'), 'BMW');
    assert.equal(nameCase('GMC', 'make'), 'GMC');
    assert.equal(nameCase('MINI', 'make'), 'MINI');
    assert.equal(nameCase('KIA', 'make'), 'Kia');
    assert.equal(nameCase('CLA250 4MATIC', 'model'), 'CLA250 4MATIC');
    assert.equal(nameCase('F-150', 'model'), 'F-150');
    assert.equal(nameCase('XLT SPORT AWD', 'trim'), 'XLT Sport AWD');
    assert.equal(nameCase('EX-L', 'trim'), 'EX-L');
    assert.equal(nameCase('R-LINE', 'trim'), 'R-Line');
    assert.equal(nameCase('HIGHLINE TSI', 'trim'), 'Highline TSI');
    assert.equal(nameCase('GRAND CHEROKEE LIMITED', 'model'), 'Grand Cherokee Limited');
  });
  it('words without a vowel, punctuation and special forms', () => {
    assert.equal(nameCase('FE, LXS', 'trim'), 'FE, LXS');
    assert.equal(nameCase('CR-V', 'model'), 'CR-V');
    assert.equal(nameCase('S', 'trim'), 'S');
    assert.equal(nameCase('XDRIVE SEDAN', 'trim'), 'xDrive Sedan');
    assert.equal(nameCase('XLT SUPERCREW 4X4', 'trim'), 'XLT SuperCrew 4X4');
    assert.equal(nameCase('GLE COUPE', 'model'), 'GLE Coupe');
    assert.equal(nameCase('CITROËN', 'make'), 'Citroën');
    assert.equal(nameCase('EXECLINE, HIGHLINE', 'trim'), 'Execline, Highline');
  });
  it('mixed case and empty values are left alone', () => {
    assert.equal(nameCase('Comfortline', 'trim'), 'Comfortline');
    assert.equal(nameCase('iX xDrive50', 'model'), 'iX xDrive50');
    assert.equal(nameCase('', 'trim'), '');
    assert.equal(nameCase(null, 'trim'), '');
    assert.equal(nameCase('4MATIC', 'trim'), '4MATIC');
  });
});
