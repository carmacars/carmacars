// REQ-141: the missing-plate rule (same as app.plate_missing, 5212).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normPlate, plateMissing, plateProblem } from './plate.ts';

test('empty, X only, zeros and placeholder words are missing; a real plate is not', () => {
  for (const p of [null, undefined, '', '  ', 'XXXXXXXX', 'xx-xx', 'TBD', 'n/a', '0000', 'Pending']) assert.equal(plateMissing(p), true, String(p));
  for (const p of ['ABCD 123', 'X1', 'CXXX123', '1234AB']) assert.equal(plateMissing(p), false, p);
});

test('a plate typed in is checked as the database checks it', () => {
  assert.equal(normPlate(' abcd-123 '), 'ABCD123');
  assert.equal(plateProblem('abcd 123'), null);
  assert.match(plateProblem('A') ?? '', /2 to 8/);
  assert.match(plateProblem('ABCDE12345') ?? '', /2 to 8/);
  assert.match(plateProblem('XXXXXXXX') ?? '', /placeholder/);
});
