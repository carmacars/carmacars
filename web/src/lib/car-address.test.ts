import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { hasAddress } from './car-address.ts';

// 0310: a fleet row without a slug never becomes a /cars/null link.
describe('car address', () => {
  it('a slug in the listing format is an address', () => {
    assert.equal(hasAddress({ slug: '2024-toyota-corolla' }), true);
  });
  it('no slug, an empty one or the wrong format: left out', () => {
    for (const slug of [null, undefined, '', ' ', 'Not A Slug', 42]) assert.equal(hasAddress({ slug }), false, String(slug));
    assert.equal(hasAddress(null), false);
  });
});
