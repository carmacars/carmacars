import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ring, cleanContext, cleanLogs, imageKind, isSensitiveField, pagePath, redact, stripUrl } from './logs.ts';

const O = 'https://carmacars.ca';

test('URLs keep their path and only harmless query keys; tokens in links are cut', () => {
  assert.equal(stripUrl('/admin/bookings/CC-123?tab=overview&email=a@b.example.test&token=abc', O), '/admin/bookings/CC-123?tab=overview');
  assert.equal(stripUrl('https://carmacars.ca/sign/Zk3q9x0aB7c8d9e0f1g2h3i4j5k6?x=1#frag', O), '/sign/:token');
  assert.equal(stripUrl('/admin/bug-reports/0b0e2f6a-1111-4222-8333-944455556666', O), '/admin/bug-reports/0b0e2f6a-1111-4222-8333-944455556666');
  assert.equal(stripUrl('https://api.stripe.example.test/v1/charges?key=sk', O), 'https://api.stripe.example.test/…');
  assert.equal(stripUrl('/staff?tab=<script>', O), '/staff');
  assert.equal(pagePath('/staff/leads?q=Jane&tab=new', O), '/staff/leads');
});

test('messages lose emails, phone numbers, keys, tokens and long hashes, and are capped', () => {
  const r = redact('Failed for jane@example.test at +1 (416) 555-0100 with Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig key cc_live_abcdef password=hunter2 ' + 'f'.repeat(40));
  assert.ok(!r.includes('jane@'), r);
  assert.ok(!r.includes('555-0100'), r);
  assert.ok(!r.includes('eyJhbGci'), r);
  assert.ok(!r.includes('cc_live_abcdef'), r);
  assert.ok(!r.includes('hunter2'), r);
  assert.ok(r.includes('[hash]'), r);
  assert.equal(redact('x'.repeat(1000)).length, 300);
  assert.equal(redact('Booking CC-1234 failed (status 500)'), 'Booking CC-1234 failed (status 500)');
  assert.match(redact(new TypeError('boom')), /TypeError: boom/);
});

test('the ring keeps the last 50, oldest first, with URLs stripped', () => {
  const ring = new Ring();
  for (let i = 0; i < 60; i++) ring.push({ kind: 'fetch', msg: `call ${i}`, url: `/api/rpc?token=t${i}`, status: 500, method: 'post' });
  const l = ring.list();
  assert.equal(l.length, 50);
  assert.equal(l[0]?.msg, 'call 10');
  assert.equal(l[49]?.url, '/api/rpc');
  assert.equal(l[49]?.method, 'POST');
});

test('what the browser sends is cleaned again on the server', () => {
  const l = cleanLogs([{ kind: 'error', msg: 'mail me at a@b.example.test', at: 'nope' }, { kind: 'evil', msg: 'x' }, 'junk',
    { kind: 'fetch', msg: 'x', url: '/pay/abcdefghijklmnopqrstuvwxyz?card=4242', status: 502.7, method: 'g e t', ray: '8a1b<script>' }], O);
  assert.equal(l.length, 2);
  assert.equal(l[0]?.msg, 'mail me at [email]');
  assert.equal(l[1]?.url, '/pay/:token');
  assert.equal(l[1]?.status, 502);
  assert.equal(l[1]?.method, 'GET');
  assert.equal(l[1]?.ray, '8a1bscript');
  assert.equal(cleanLogs(Array.from({ length: 80 }, (_, i) => ({ kind: 'warn', msg: String(i) }))).length, 50);
  assert.deepEqual(cleanContext({ viewport: '390x844', dpr: 3, evil: 'x', browser: { a: 1 } }), { viewport: '390x844', dpr: 3 });
});

test('screenshots: only PNG, JPEG or WebP by their bytes; sensitive fields are masked', () => {
  assert.equal(imageKind(new Uint8Array([0x89, 0x50, 0x4e, 0x47]))?.ext, 'png');
  assert.equal(imageKind(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))?.ext, 'jpg');
  assert.equal(imageKind(new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]))?.ext, 'webp');
  assert.equal(imageKind(new Uint8Array([0x3c, 0x73, 0x76, 0x67])), null);
  assert.ok(isSensitiveField({ type: 'password' }));
  assert.ok(isSensitiveField({ sensitive: true }));
  assert.ok(isSensitiveField({ autocomplete: 'cc-number' }));
  assert.ok(isSensitiveField({ name: 'card_cvc' }));
  assert.ok(!isSensitiveField({ type: 'text', name: 'notes' }));
});
