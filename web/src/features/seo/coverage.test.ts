// The index coverage report (release 28, B7).   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { coverageBucket, coverageShares, emptyBuckets, pageKind, pickSample } from './coverage.ts';

test('coverage states in five buckets (1103: unknown to Google apart, any indexed state, the verdict)', () => {
  assert.equal(coverageBucket('Submitted and indexed'), 'indexed');
  assert.equal(coverageBucket('Indexed, not submitted in sitemap'), 'indexed');
  assert.equal(coverageBucket('Indexed, though blocked by robots.txt'), 'indexed');
  assert.equal(coverageBucket('Some new wording', 'PASS'), 'indexed');
  assert.equal(coverageBucket('Crawled - currently not indexed'), 'crawled');
  assert.equal(coverageBucket('Discovered - currently not indexed'), 'discovered');
  assert.equal(coverageBucket('URL is unknown to Google'), 'unknown');
  assert.equal(coverageBucket('Page with redirect'), 'other');
  assert.equal(coverageBucket('Excluded by \'noindex\' tag'), 'other');
});

test('the miscount: 19 indexed of 1,649 inspected was over every address, most of them unknown to Google', () => {
  // a day like the one Admin showed: the long tail mostly unknown to Google
  const b = { ...emptyBuckets(), indexed: 19, crawled: 14, discovered: 3, unknown: 1600, other: 13 };
  const s = coverageShares(b);
  assert.equal(s.inspected, 1649);
  assert.equal(s.known, 49);
  assert.equal(Math.round(s.indexedOfAll! * 100), 1);
  assert.equal(Math.round(s.indexedOfKnown! * 100), 39);
  assert.equal(coverageShares(emptyBuckets()).indexedOfKnown, null);
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
