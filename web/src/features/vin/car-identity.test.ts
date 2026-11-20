import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { carBody, carIdentity, familyGroups } from './car-identity.ts';

// The same cases as supabase/tests/99_r48an_renders_identity.sql (app.car_identity, 3151).
const CASES = JSON.parse(readFileSync(new URL('./car-identity.cases.json', import.meta.url), 'utf8')) as Array<[string, string, string | null, string, string, string | null]>;

describe('one make, model family and trim per car (3151)', () => {
  for (const [make, model, trim, wMake, wModel, wTrim] of CASES) {
    it(`${make} ${model}${trim ? ` / ${trim}` : ''}`, () => {
      const id = carIdentity(make, model, trim);
      assert.deepEqual([id.make, id.model, id.trim], [wMake, wModel, wTrim]);
    });
  }
  it('an unknown model of a make we keep families for is flagged, another make is not', () => {
    assert.equal(carIdentity('Audi', 'Zeppelin', null).known, false);
    assert.equal(carIdentity('Acme', 'Thing', null).known, null);
  });
  it('one body name', () => {
    assert.deepEqual(['Compact SUV', 'Mid-size sedan', 'Four-door coupe', 'Pickup truck', 'Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)', 'Cabriolet', 'Minivan', 'Hatchback'].map(carBody),
      ['SUV', 'Sedan', 'Coupe', 'Pickup truck', 'SUV', 'Convertible', 'Minivan', 'Hatchback']);
  });
  it('the filter lists families only: CLA 250 and CLA-Class are one option', () => {
    const g = familyGroups([{ make: 'Mercedes', model: 'CLA 250' }, { make: 'Mercedes-Benz', model: 'CLA-Class', trim: 'CLA250-4M' }, { make: 'BMW', model: '330i' }, { make: 'BMW', model: '3 Series', trim: 'M340i' }]);
    assert.deepEqual(g, [{ make: 'BMW', families: [{ model: '3 Series', count: 2 }] }, { make: 'Mercedes-Benz', families: [{ model: 'CLA-Class', count: 2 }] }]);
  });
});
