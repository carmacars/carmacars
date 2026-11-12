import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { areasFor, topicsFor, typingIn } from './areas.ts';

// Live updates (release 41): which areas each portal screen watches, and when a refresh waits for typing.
describe('live areas', () => {
  it('maps every key screen of every portal', () => {
    assert.deepEqual(areasFor('/admin/bookings'), ['me', 'bookings']);
    assert.deepEqual(areasFor('/staff/bookings?tab=today'), ['me', 'bookings']);
    assert.deepEqual(areasFor('/admin/bookings/new'), ['me', 'bookings']);
    assert.deepEqual(areasFor('/admin/bookings/CC-1234'), ['me'], 'a booking page watches its own booking (LiveBooking)');
    assert.deepEqual(areasFor('/staff/bookings/CC-1234/handover/x'), ['me']);
    assert.deepEqual(areasFor('/admin/requests'), ['me', 'requests', 'bookings']);
    assert.deepEqual(areasFor('/staff/offers'), ['me', 'requests', 'bookings']);
    assert.deepEqual(areasFor('/staff/leads'), ['me', 'leads']);
    assert.deepEqual(areasFor('/admin/sales-leads'), ['me', 'leads']);
    assert.deepEqual(areasFor('/staff/messages'), ['me', 'messages']);
    assert.deepEqual(areasFor('/admin/calendar'), ['me', 'bookings', 'requests', 'field']);
    assert.deepEqual(areasFor('/staff/today'), ['me', 'bookings', 'requests', 'field']);
    assert.deepEqual(areasFor('/admin/field-jobs'), ['me', 'field']);
    assert.deepEqual(areasFor('/staff/field/jobs/1'), ['me', 'field']);
    assert.deepEqual(areasFor('/staff/schedule'), ['me', 'field']);
    assert.deepEqual(areasFor('/admin'), ['me', 'bookings', 'requests', 'leads', 'field']);
    assert.deepEqual(areasFor('/admin/alerts'), ['me']);
    assert.deepEqual(areasFor('/account/bookings/CC-1'), ['me', 'renter']);
    assert.deepEqual(areasFor('/owner'), ['me', 'owner']);
    assert.deepEqual(areasFor('/cars/x'), [], 'public pages watch nothing');
  });

  it('keeps only the tokens the server gave', () => {
    assert.deepEqual(topicsFor('/staff/today', { me: 'm0000000', bookings: 'b0000000' }), ['m0000000', 'b0000000']);
    assert.deepEqual(topicsFor('/staff/leads', {}), []);
  });

  it('waits only for fields someone types in', () => {
    assert.equal(typingIn({ tagName: 'INPUT', type: 'text' }), true);
    assert.equal(typingIn({ tagName: 'input' }), true);
    assert.equal(typingIn({ tagName: 'TEXTAREA' }), true);
    assert.equal(typingIn({ tagName: 'DIV', isContentEditable: true }), true);
    assert.equal(typingIn({ tagName: 'INPUT', type: 'checkbox' }), false);
    assert.equal(typingIn({ tagName: 'BUTTON' }), false);
    assert.equal(typingIn({ tagName: 'INPUT', type: 'text', readOnly: true }), false);
    assert.equal(typingIn(null), false);
  });
});
