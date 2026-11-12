import { test } from 'node:test';
import assert from 'node:assert/strict';
import { alsoSearched, synonymTreePath, termTreeRedirect } from './synonyms.ts';

test('2402: the group page lists its synonyms on one line, without repeats; none, no line', () => {
  assert.equal(alsoSearched(['car hire', 'cars for hire', 'vehicle rental']), 'Also searched as: car hire, cars for hire, vehicle rental');
  assert.equal(alsoSearched(['car hire', ' Car hire ', '']), 'Also searched as: car hire');
  assert.equal(alsoSearched([]), null);
  assert.equal(alsoSearched(undefined), null);
});

test('2402: a synonym tree answers 301 with its group tree, the car rental group with /cars', () => {
  const map = { 'car-hire': '', 'auto-detailing': 'car-detailing', 'vinyl-wrap': 'car-wrap' };
  assert.equal(termTreeRedirect(['car-hire', 'toyota', 'camry', '2020'], map), '/cars/toyota/camry/2020');
  assert.equal(termTreeRedirect(['car-hire'], map), '/cars');
  assert.equal(termTreeRedirect(['auto-detailing', 'honda', 'civic', '2019', 'ex', 'markham-on'], map), '/t/car-detailing/honda/civic/2019/ex/markham-on');
  assert.equal(termTreeRedirect(['vinyl-wrap'], map), '/t/car-wrap');
  assert.equal(termTreeRedirect(['car-detailing', 'honda'], map), null, 'a group term is served, not redirected');
  assert.equal(termTreeRedirect(['toString'], map), null, 'only the map\'s own keys');
  assert.equal(termTreeRedirect(['car-hire', 'bmw'], undefined), null);
  assert.equal(termTreeRedirect(['auto-detailing', 'bmw'], map, 'fr'), '/fr/t/car-detailing/bmw');
  assert.equal(termTreeRedirect(['car-hire', 'bmw'], map, 'zh-hk'), '/zh-hk/cars/bmw');
  assert.equal(termTreeRedirect(['car-hire', 'bmw'], map, '/evil.example.test'), null, 'never off the site');
  assert.equal(synonymTreePath('', []), '/cars');
});
