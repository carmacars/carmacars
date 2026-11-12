// The crash listener's filter (r40).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NOISE, foreignError } from './noise.ts';

const O = 'https://example.test';
test('foreignError: extension and injected scripts are left out, our own crashes are kept', () => {
  assert.equal(foreignError(O, 'chrome-extension://abc/content.js', ''), true);
  assert.equal(foreignError(O, `${O}/_next/static/chunks/app.js`, ''), false);
  assert.equal(foreignError(O, '', "TypeError: Cannot read properties of undefined (reading 'toLowerCase')\n    at e (chrome-extension://abc/inject.js:1:200)"), true);
  assert.equal(foreignError(O, '', `TypeError: x\n    at f (${O}/_next/static/chunks/12.js:1:99)`), false);
  assert.equal(foreignError(O, '', 'TypeError: no frames'), false);
  assert.equal(foreignError(O, null, undefined), false);
});
test('NOISE: chunk and abort errors are not crashes', () => {
  assert.ok(NOISE.test('ChunkLoadError: Loading chunk 12 failed'));
  assert.ok(!NOISE.test("Cannot read properties of undefined (reading 'toLowerCase')"));
});
