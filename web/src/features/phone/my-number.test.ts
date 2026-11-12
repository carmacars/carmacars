import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callView, checkMyNumber } from './my-number.ts';

// r40 hotfix (2460): the "your mobile number" pop-up of the Call button
test('a Canadian or US mobile typed any way is saved as +1 and shown as (NXX) NXX-XXXX', () => {
  for (const s of ['647 555 0123', '(647) 555-0123', '647.555.0123', '+1 647 555 0123', '1-647-555-0123', ' 6475550123 ']) {
    const r = checkMyNumber(s);
    assert.ok(r.ok, s);
    if (r.ok) { assert.equal(r.e164, '+16475550123'); assert.equal(r.display, '(647) 555-0123'); }
  }
  assert.ok(checkMyNumber('212-555-0199').ok);
});

test('anything else is refused with what to type', () => {
  assert.equal(checkMyNumber('').ok, false);
  for (const s of ['555 0123', '647 555 012', '+63 917 555 0100', '911', '047 555 0123', '647 055 0123', '411 555 0123', 'call me', '647 555 0123 ext 2']) {
    const r = checkMyNumber(s);
    assert.equal(r.ok, false, s);
    if (!r.ok) assert.match(r.message, /mobile|number/i, s);
  }
  const ph = checkMyNumber('+63 917 555 0100');
  assert.ok(!ph.ok && /Canadian and US/.test(ph.message));
});

test('the call answer: ringing, ask for the number, or a message saying what to do', () => {
  assert.deepEqual(callView({ ok: true, calling: '••••0123' }, true), { kind: 'ringing', calling: '••••0123' });
  const ask = callView({ ok: false, need_phone: true, message: 'Add your mobile number first' }, true);
  assert.equal(ask.kind, 'ask_number');
  const off = callView({ ok: false, fallback: 'quo', message: 'Calling from the site is not set up yet.' }, true);
  assert.ok(off.kind === 'problem' && /ask customer service or an Admin/.test(off.message));
  const plain = callView({ ok: false, fallback: 'quo', message: 'Calling from the site is not set up yet.' }, false);
  assert.ok(plain.kind === 'problem' && !/hidden for Sales/.test(plain.message));
  // never an empty message: a failure always says something
  const empty = callView({ ok: false }, true);
  assert.ok(empty.kind === 'problem' && empty.message.length > 10);
  assert.equal(callView(null, false).kind, 'problem');
});
