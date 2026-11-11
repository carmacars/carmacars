import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AGREEMENT_PARTS, AGREEMENT_TEMPLATE_VERSION } from './source.generated.ts';

// r35 fix (1700): rideshare and delivery driving are welcome; every other prohibited use stays.
test('the rental terms welcome rideshare and delivery driving', () => {
  const t = AGREEMENT_PARTS['2'].body;
  assert.match(t, /\*\*10\.3 Rideshare and delivery driving are welcome\.\*\*/);
  assert.doesNotMatch(t, /including ride-hailing and delivery work/);
  for (const kept of ['re-rent it or list it on a car-sharing platform', 'racing, stunt driving', 'to tow anything', 'to smoke or vape', '**10.4 Care.**', 'a use prohibited by section 10.2'])
    assert.ok(t.includes(kept), kept);
  assert.notEqual(AGREEMENT_TEMPLATE_VERSION, 'rental-v3-c194f2e4d1', 'a new version: signed agreements keep theirs');
});
