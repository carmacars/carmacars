import { test } from 'node:test';
import assert from 'node:assert/strict';
import { foreignOrigin, sameSecret } from './same-origin.ts';

test('no Origin header, or this site: let through', () => {
  assert.equal(foreignOrigin(null, 'www.example.test'), false);
  assert.equal(foreignOrigin('', 'www.example.test'), false);
  assert.equal(foreignOrigin('https://www.example.test', 'www.example.test'), false);
  assert.equal(foreignOrigin('http://localhost:3000', 'localhost:3000'), false);
});

test('another site, or an Origin that is not an address: refused, never thrown', () => {
  assert.equal(foreignOrigin('https://other.example.test', 'www.example.test'), true);
  assert.equal(foreignOrigin('https://www.example.test:8443', 'www.example.test'), true);
  for (const o of ['null', 'not a url', '://', 'https://', '%%%']) assert.equal(foreignOrigin(o, 'www.example.test'), true, o);
  assert.equal(foreignOrigin('https://www.example.test', null), true);
});

test('secrets: equal only when every character and the length match', () => {
  assert.equal(sameSecret('Bearer abc123', 'Bearer abc123'), true);
  for (const g of ['', 'Bearer abc124', 'Bearer abc12', 'Bearer abc1234', 'bearer abc123']) assert.equal(sameSecret(g, 'Bearer abc123'), false, g);
  assert.equal(sameSecret('', ''), true);
});
