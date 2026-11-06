// The index coverage report (release 28, B7).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { coverageBucket, pageKind, pickSample } from './coverage.ts';

test('coverage states in four buckets', () => {
  assert.equal(coverageBucket('Submitted and indexed'), 'indexed');
  assert.equal(coverageBucket('Crawled - currently not indexed'), 'crawled');
  assert.equal(coverageBucket('Discovered - currently not indexed'), 'discovered');
  assert.equal(coverageBucket('URL is unknown to Google'), 'other');
});

test('kinds of page', () => {
  assert.equal(pageKind('/cars/2024-mercedes-c300-black'), 'car');
  assert.equal(pageKind('/car-rental/port-credit'), 'place');
  assert.equal(pageKind('/rent/suv-rental'), 'place');
  assert.equal(pageKind('/guides/407-etr'), 'guide');
  assert.equal(pageKind('/faq'), 'other');
});

test('the sample: a third priority, the rest long tail, no repeats, another slice each run', () => {
  const pr = Array.from({ length: 30 }, (_, i) => `/p${i}`), tail = Array.from({ length: 300 }, (_, i) => `/t${i}`);
  const a = pickSample(pr, tail, 30, 1), b = pickSample(pr, tail, 30, 2);
  assert.equal(a.length, 30);
  assert.equal(new Set(a).size, 30);
  assert.equal(a.filter((u) => u.startsWith('/p')).length, 10);
  assert.notDeepEqual(a, b);
  assert.equal(pickSample([], ['/x'], 5, 0).length, 1);
});
