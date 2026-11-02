import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { familyTree, modelFamily } from './model-family.ts';

// The same cases as supabase/tests/99_model_family.sql (app.car_model_family): every make, model and trim in the seeds, the
// shapes VIN decode, permit scans and partner sheets give, and values that must stay exactly as typed.
const CASES = JSON.parse(readFileSync(new URL('./model-family.cases.json', import.meta.url), 'utf8')) as Array<[string, string, string | null, string, string | null]>;

describe('one model per family, the code in the trim (0520)', () => {
  for (const [make, model, trim, wantModel, wantTrim] of CASES) {
    it(`${make} ${model}${trim ? ` / ${trim}` : ''}`, () => {
      const f = modelFamily(make, model, trim);
      assert.deepEqual([f.model, f.trim], [wantModel, wantTrim]);
    });
  }
  it('applying it twice changes nothing', () => {
    for (const [make, model, trim] of CASES) {
      const a = modelFamily(make, model, trim), b = modelFamily(make, a.model, a.trim);
      assert.deepEqual([b.model, b.trim], [a.model, a.trim], `${make} ${model} ${trim}`);
    }
  });
  it('known: a Mercedes-Benz or BMW family is known, an unreadable model is not, other makes are not judged', () => {
    assert.equal(modelFamily('Mercedes-Benz', 'C300', null).known, true);
    assert.equal(modelFamily('Mercedes-Benz', 'Something', null).known, false);
    assert.equal(modelFamily('BMW', 'X5', null).known, true);
    assert.equal(modelFamily('Honda', 'Civic', null).known, null);
  });
  it('the /cars filter: C-Class and C300 are one model with their trims nested', () => {
    const tree = familyTree([{ make: 'Mercedes-Benz', model: 'C-Class', trim: 'C43 AMG' }, { make: 'Mercedes-Benz', model: 'C300', trim: '4MATIC' },
      { make: 'Mercedes-Benz', model: 'CLA250', trim: null }, { make: 'Mercedes-Benz', model: 'CLA-Class', trim: 'CLA250 4MATIC' }, { make: 'BMW', model: 'X5', trim: null }]);
    assert.deepEqual(tree, [
      { make: 'BMW', families: [{ model: 'X5', trims: [] }] },
      { make: 'Mercedes-Benz', families: [{ model: 'C-Class', trims: ['C43 AMG', 'C300 4MATIC'] }, { model: 'CLA-Class', trims: ['CLA250', 'CLA250 4MATIC'] }] }]);
  });
});
