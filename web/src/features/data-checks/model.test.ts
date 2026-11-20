import { test } from 'node:test';
import assert from 'node:assert/strict';
import { closable, inputsOf, order, type DataIssue } from './model.ts';

const w: DataIssue = { key: 'staff_phone', audience: 'staff', severity: 'warning', label: '', message: '', allow_confirm: false, fix: { kind: 'phone', value: '123' } };
const b: DataIssue = { key: 'staff_agreement', audience: 'staff', severity: 'blocking', label: '', message: '', allow_confirm: false, fix: { kind: 'agreement', fields: ['licence', 'address'] } };

test('blocking first, and the pop-up stays open while one is there', () => {
  assert.deepEqual(order([w, b]).map((x) => x.key), ['staff_agreement', 'staff_phone']);
  assert.equal(closable([w]), true);
  assert.equal(closable([w, b]), false);
});

test('each fix asks for its inputs', () => {
  assert.deepEqual(inputsOf(b).map((x) => x.name), ['licence_number', 'licence_expiry', 'home_address', 'home_postal_code']);
  assert.deepEqual(inputsOf(w).map((x) => [x.name, x.value]), [['phone', '123']]);
  assert.equal(inputsOf({ ...w, fix: { kind: 'whatsapp_tag', tag: 'Darren - Sales' } })[0]!.label, 'I set my member tag "Darren - Sales" in each group');
  assert.deepEqual(inputsOf({ ...w, fix: { kind: 'link', href: '/staff/profile#pay' } }), []);
});
