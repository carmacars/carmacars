import { test } from 'node:test';
import assert from 'node:assert/strict';
import { captureNote, cleanEmail, cleanFields, cleanName, cleanPhone } from './fields.ts';

test('only valid values are kept', () => {
  assert.equal(cleanName(' Maya   Chen '), 'Maya Chen');
  assert.equal(cleanName('M'), undefined);
  assert.equal(cleanName('x'.repeat(121)), undefined);
  assert.equal(cleanEmail(' Maya@Example.COM '), 'maya@example.com');
  assert.equal(cleanEmail('maya@example'), undefined);
  assert.equal(cleanEmail('maya@'), undefined);
  assert.equal(cleanPhone('(647) 555-0142'), '(647) 555-0142');
  assert.equal(cleanPhone('555-0142'), undefined);
  assert.equal(cleanPhone('+44 20 7946 0958 1234 5'), undefined);
  assert.equal(cleanName(42), undefined);
});

test('a half-typed field is left out, the rest saved', () => {
  assert.deepEqual(cleanFields({ name: 'Maya Chen', email: 'maya@exa', phone: '' }), { name: 'Maya Chen' });
  assert.deepEqual(cleanFields({ email: 'a@b.co', phone: '416 555 0100' }), { email: 'a@b.co', phone: '416 555 0100' });
  assert.deepEqual(cleanFields({}), {});
});

test('the note never says more about an existing account than the spec allows', () => {
  assert.equal(captureNote({ ok: true, state: 'existing', linkSent: true })?.text, 'You have an account: we sent you a sign-in link.');
  const later = captureNote({ ok: true, state: 'existing', linkSent: false, linkSentBefore: true });
  assert.equal(later?.signIn, true);
  assert.doesNotMatch(later!.text, /password|confirmed|booking|name/i);
  assert.match(captureNote({ ok: true, state: 'new' })!.text, /opened an account/);
  assert.equal(captureNote({ ok: true, state: 'this_device' }), null);
  assert.equal(captureNote({ ok: true, state: 'phone_only' }), null);
  assert.equal(captureNote({ ok: false }), null);
  assert.equal(captureNote(null), null);
});
