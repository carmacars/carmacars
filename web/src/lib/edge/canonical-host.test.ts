import assert from 'node:assert/strict';
import { test } from 'node:test';
import { hostAction } from './canonical-host.ts';

const C = 'https://carmacars.ca';
test('the canonical host passes; www answers one permanent redirect that keeps the path and the query', () => {
  assert.deepEqual(hostAction('carmacars.ca', C, 'GET', '/cars'), { kind: 'pass' });
  assert.deepEqual(hostAction('CarmaCars.ca:443', C, 'GET', '/cars'), { kind: 'pass' });
  assert.deepEqual(hostAction('www.carmacars.ca', C, 'GET', '/car-rental/toronto?from=2026-12-01'), { kind: 'redirect', location: 'https://carmacars.ca/car-rental/toronto?from=2026-12-01' });
  assert.deepEqual(hostAction('www.carmacars.ca', C, 'HEAD', '/'), { kind: 'redirect', location: 'https://carmacars.ca/' });
  // when www is the canonical one, the bare domain redirects to it
  assert.deepEqual(hostAction('carmacars.ca', 'https://www.carmacars.ca', 'GET', '/faq'), { kind: 'redirect', location: 'https://www.carmacars.ca/faq' });
});

test('the API, the build files, the health check and writes are never redirected', () => {
  for (const p of ['/api/health', '/api/webhooks/stripe', '/_next/static/x.js', '/healthz']) assert.deepEqual(hostAction('www.carmacars.ca', C, 'GET', p), { kind: 'pass' }, p);
  assert.deepEqual(hostAction('www.carmacars.ca', C, 'POST', '/contact'), { kind: 'pass' });
});

test('another hostname of the domain keeps answering, marked noindex; anything else is left alone', () => {
  assert.deepEqual(hostAction('new.carmacars.ca', C, 'GET', '/'), { kind: 'noindex' });
  assert.deepEqual(hostAction('new.carmacars.ca', C, 'GET', '/api/health'), { kind: 'noindex' });
  for (const h of ['localhost:3000', '127.0.0.1:3470', 'carmacars-web:3000', 'preview.example.test', 'notcarmacars.ca', 'evilcarmacars.ca', '', null]) assert.deepEqual(hostAction(h, C, 'GET', '/'), { kind: 'pass' }, String(h));
  assert.deepEqual(hostAction('www.carmacars.ca', 'http://localhost:3000', 'GET', '/'), { kind: 'pass' }, 'a local build redirects nothing');
  assert.deepEqual(hostAction('www.carmacars.ca', '', 'GET', '/'), { kind: 'pass' });
});
