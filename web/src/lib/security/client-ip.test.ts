import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clientIp, NO_IP } from './client-ip.ts';

const h = (o: Record<string, string>) => (n: string) => o[n] ?? null;

test('production reads CF-Connecting-IP only, never the headers a caller writes', () => {
  assert.equal(clientIp(h({ 'cf-connecting-ip': '203.0.113.7', 'x-forwarded-for': '198.51.100.1' }), true), '203.0.113.7');
  assert.equal(clientIp(h({ 'x-forwarded-for': '198.51.100.1, 203.0.113.7' }), true), NO_IP);
  assert.equal(clientIp(h({ 'x-real-ip': '198.51.100.1' }), true), NO_IP);
  assert.equal(clientIp(h({ 'cf-connecting-ip': '2001:db8::1' }), true), '2001:db8::1');
});

test('production without a usable address shares one address, so a limit by address still counts (fails closed)', () => {
  assert.equal(clientIp(h({}), true), NO_IP);
  assert.equal(clientIp(h({ 'cf-connecting-ip': 'not an address' }), true), NO_IP);
  assert.equal(clientIp(h({ 'cf-connecting-ip': `1${'1'.repeat(60)}` }), true), NO_IP);
});

test('the local stack and the tests read the proxy headers, and a missing address is null', () => {
  assert.equal(clientIp(h({ 'x-forwarded-for': ' 198.51.100.1 , 10.0.0.1' }), false), '198.51.100.1');
  assert.equal(clientIp(h({ 'x-real-ip': '198.51.100.2' }), false), '198.51.100.2');
  assert.equal(clientIp(h({ 'cf-connecting-ip': '203.0.113.7', 'x-forwarded-for': '198.51.100.1' }), false), '203.0.113.7');
  assert.equal(clientIp(h({}), false), null);
});
