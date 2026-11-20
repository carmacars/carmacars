import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AGREEMENT_PARTS, AGREEMENT_TEMPLATE_VERSION } from './source.generated.ts';

// r48 MR (3102): the speeding charges are a clause of their own and three separate lines of the Fee Schedule; the text is a
// new version, so agreements already signed keep theirs (nobody signs again).
test('the rental terms charge speeding over 180, 220 and 300 km/h, each as its own charge', () => {
  const terms = AGREEMENT_PARTS['2'].body;
  assert.match(terms, /\*\*10\.5 Speeding charges\.\*\*/);
  // r48 TRK (3323, the owner on Nov 20): one event is one charge, at the highest limit reached
  assert.match(terms, /one speeding charge for that event, at the highest limit reached/);
  assert.match(terms, /one event is one charge/);
  assert.doesNotMatch(terms, /each limit is a separate charge/);
  assert.match(terms, /from the Deposit first/);
  const fees = AGREEMENT_PARTS['3'].body;
  for (const limit of ['180', '220', '300']) assert.match(fees, new RegExp(`\\| Speeding charge, over ${limit} km/h \\|`));
  assert.notEqual(AGREEMENT_TEMPLATE_VERSION, 'rental-v3-c194f2e4d1');
  assert.notEqual(AGREEMENT_TEMPLATE_VERSION, 'rental-v3-6a79e5ecb2', 'a new version again for the one-charge wording');
  // r48 TRK (3324): leaving Canada needs written approval
  assert.match(terms, /out of Canada always requires our written approval before you leave/);
});
