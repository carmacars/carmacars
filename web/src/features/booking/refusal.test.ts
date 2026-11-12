import assert from 'node:assert/strict';
import { test } from 'node:test';
import { KEPT_HERE, addonsNote, refusalResult, transient, uniqueDrivers } from './refusal.ts';

test('a refusal with a field puts the same message beside that field', () => {
  const r = refusalResult({ code: 'notice', field: 'dates', message: 'Pickup needs at least 2 hours of notice from now. Choose a later pickup time.', unexpected: false });
  assert.deepEqual(r, { ok: false, code: 'notice', message: 'Pickup needs at least 2 hours of notice from now. Choose a later pickup time.', fieldErrors: { dates: 'Pickup needs at least 2 hours of notice from now. Choose a later pickup time.' } });
});
test('a refusal without a field has the message only', () => {
  assert.equal(refusalResult({ code: 'rate_limited', field: null, message: 'Wait an hour.', unexpected: false }).fieldErrors, undefined);
});
test('no reason read: the answers are saved on the device, and nobody is told to call', () => {
  assert.equal(refusalResult(null).message, KEPT_HERE);
  assert.equal(refusalResult(null).code, 'unexpected');
  assert.doesNotMatch(KEPT_HERE, /call us/i);
});
test('an unexpected error says staff will contact them only when the follow-up was kept', () => {
  const m = 'Something went wrong on our side, not yours. We kept your request and our team will contact you to finish it.';
  assert.equal(refusalResult({ code: 'unexpected', field: null, message: m, unexpected: true, logged: true }).message, m);
  assert.equal(refusalResult({ code: 'unexpected', field: null, message: m, unexpected: true, logged: false }).message, KEPT_HERE);
});
test('the renter and a driver listed twice are sent once', () => {
  const renter = { full_name: 'Ana  Diaz', date_of_birth: '1990-01-02' };
  const out = uniqueDrivers(renter, [{ full_name: 'ana diaz', date_of_birth: '1990-01-02' }, { full_name: 'Ben Roy', date_of_birth: '1991-03-04' }, { full_name: 'Ben  Roy ', date_of_birth: '1991-03-04' }, { full_name: 'Ben Roy', date_of_birth: '1992-03-04' }]);
  assert.deepEqual(out.map((d) => d.date_of_birth), ['1991-03-04', '1992-03-04']);
});
test('a busy database or no answer is tried once more; a refusal is not', () => {
  assert.equal(transient(new TypeError('fetch failed')), true);
  assert.equal(transient(Object.assign(new Error('canceling statement due to statement timeout'), { name: 'DbError', code: '57014' })), true);
  assert.equal(transient(Object.assign(new Error('A mobile number is needed'), { name: 'DbError', code: '22023' })), false);
});
test('the add-ons a request is sent without are named for staff, inside the note limit', () => {
  assert.equal(addonsNote('Flight AC 123', [{ code: 'baby_seat', quantity: 2 }, { code: 'chauffeur', quantity: 1, hours: 4 }, { code: 'x', quantity: 0 }], 500),
    'Add-ons asked for, not added online, please confirm: 2 x baby seat, 1 x chauffeur (4 h). Flight AC 123');
  assert.equal(addonsNote('y'.repeat(600), [{ code: 'baby_seat', quantity: 1 }], 500).length, 500);
});
