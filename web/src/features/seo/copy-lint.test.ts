import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lintSource, negativeHits, stripComments } from './copy-lint.ts';
import { styleProblems } from './copy.ts';
import { pickSimilar, steer } from './steer.ts';

test('the negative phrases are found, the positive ones pass', () => {
  for (const bad of ['This car is not available.', 'We don’t have that model.', 'We do not offer leases.', 'No car matches this right now.', 'Not from our fleet right now.',
    'CarmaCars has no location in Barrie.', 'Sold out this week.', 'The catalog has no Kia models yet.']) assert.ok(negativeHits(bad).length > 0, bad);
  for (const good of ['Request this exact car and we look for one for your dates.', 'Similar cars ready to book now.', 'No payment until we confirm.', 'CarmaCars is not affiliated with Turo.',
    'NHTSA lists no recall campaign for this model year.']) assert.equal(negativeHits(good).length, 0, good);
});

test('comments are skipped, text is not', () => {
  const src = "// we do not offer this\nconst a = 'x'; /* not available */\nconst b = `We do not offer it`;\n{/* sold out */}";
  assert.deepEqual(lintSource(src).map((h) => h.line), [3]);
  assert.equal(stripComments('url: "https://example.test/x"').includes('https://example.test/x'), true);
  assert.equal(lintSource("-- we do not offer\nselect 'fine';", true).length, 0);
});

test('written copy with a negative phrase is refused by the search copy checks', () => {
  assert.ok(styleProblems('This model is not available in Toronto.').some((p) => /positively/.test(p)));
  assert.equal(styleProblems('Similar cars are ready to book now.').filter((p) => /positively/.test(p)).length, 0);
});

test('demand steering: the popular car goes last, and the similar cars rotate by page', () => {
  const cars = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].map((id) => ({ vehicle_id: id, popular: id === 'a' }));
  assert.deepEqual(steer(cars).map((c) => c.vehicle_id), ['b', 'c', 'd', 'e', 'f', 'g', 'a']);
  assert.deepEqual(steer(cars.map((c) => ({ ...c, popular: false })), ['b']).map((c) => c.vehicle_id).at(-1), 'b');
  const one = pickSimilar(cars, 3, '/cars/x').map((c) => c.vehicle_id);
  assert.equal(one.length, 3); assert.ok(!one.includes('a')); assert.equal(one[0], 'b');
  const pages = new Set(['/cars/x', '/cars/y', '/cars/z', '/cars/w'].map((k) => pickSimilar(cars, 3, k).map((c) => c.vehicle_id).join()));
  assert.ok(pages.size > 1, 'pages show different similar cars');
  assert.deepEqual(pickSimilar(cars, 3, '/cars/x'), pickSimilar(cars, 3, '/cars/x'));
  assert.deepEqual(pickSimilar(cars.slice(0, 2), 3, 'k').map((c) => c.vehicle_id), ['b', 'a']);
});
