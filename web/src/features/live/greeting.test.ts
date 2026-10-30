import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { greetingAllowed, greetingWait } from './greeting.ts';

// The chat greeting (migration 0100): where and when it opens.
describe('the chat greeting', () => {
  it('on the public site, car and service pages included', () => {
    for (const p of ['/', '/cars', '/cars/mercedes-benz-a220', '/faq', '/chauffeur', '/detailing/ceramic/toronto', '/body-shop', '/car-rental/toronto', '/list-your-car'])
      assert.equal(greetingAllowed(p), true, p);
  });
  it('never in the portals, sign-in, booking, checkout or payment pages', () => {
    for (const p of ['/account', '/account/bookings/CC-1', '/owner', '/owner/cars', '/admin', '/staff/live', '/staff/field', '/investor', '/sign-in', '/sign/driver/x', '/create-account',
      '/book', '/book/tesla-model-3', '/book/sent/CC-1', '/checkout', '/pay/x', '/x/pay', '/my-request/abc', '/continue/abc'])
      assert.equal(greetingAllowed(p), false, p);
  });
  it('45 seconds from the first page of the visit, across pages', () => {
    const start = 1_000_000;
    assert.equal(greetingWait({ after: 45, start, now: start }), 45_000);
    assert.equal(greetingWait({ after: 45, start, now: start + 30_000 }), 15_000);
    assert.equal(greetingWait({ after: 45, start, now: start + 90_000 }), 0);
  });
  it('once a visit, never with a chat going, never when off', () => {
    assert.equal(greetingWait({ after: 45, start: 0, now: 0, done: true }), null);
    assert.equal(greetingWait({ after: 45, start: 0, now: 0, chatting: true }), null);
    assert.equal(greetingWait({ after: 0, start: 0, now: 0 }), null);
  });
});
