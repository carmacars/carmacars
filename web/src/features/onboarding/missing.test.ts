import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readableDetail, readableMissing } from './missing.ts';

test('the internal PDF box names are left out of what a form misses', () => {
  assert.deepEqual(readableMissing(['Body type', 'PDF field form1[0].page1[0].body[0].orgName[0]']), ['Body type']);
  assert.deepEqual(readableMissing(['PDF field nameRecipient']), ['a box of the official form (we fill it in)']);
  assert.deepEqual(readableMissing([]), []);
  assert.equal(readableDetail('Missing: Body type, Corporation name, PDF field form1[0].page1[0].body[0].SectionB[0].#subform[0].busname[0]'), 'Missing: Body type, Corporation name');
  assert.equal(readableDetail('Not signed'), 'Not signed');
});
