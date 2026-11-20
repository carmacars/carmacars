import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AGREEMENT_PARTS, AGREEMENT_TEMPLATE_VERSION } from './source.generated.ts';

// r48 MR (3102): the speeding charges are a clause of their own and three separate lines of the Fee Schedule; the text is a
// new version, so agreements already signed keep theirs (nobody signs again).
test('the rental terms charge speeding over 180, 220 and 300 km/h, each as its own charge', () => {
  const terms = AGREEMENT_PARTS['2'].body;
  assert.match(terms, /\*\*10\.5 Speeding charges\.\*\*/);
  assert.match(terms, /each limit is a separate charge/);
  assert.match(terms, /from the Deposit first/);
  const fees = AGREEMENT_PARTS['3'].body;
  for (const limit of ['180', '220', '300']) assert.match(fees, new RegExp(`\\| Speeding charge, over ${limit} km/h \\|`));
  assert.notEqual(AGREEMENT_TEMPLATE_VERSION, 'rental-v3-c194f2e4d1');
});
