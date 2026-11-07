// One-step Hire (release 33): the invitation of each function and the agreement values from the Hire form.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { HIRE_FUNCTIONS, agreementValues, inviteFor, payCents } from './hire.ts';

test('each function invites into the one staff portal with the right function', () => {
  assert.deepEqual(inviteFor('cs', ['finance']), { role: 'staff', functions: ['cs', 'finance'], work_mode: null });
  assert.deepEqual(inviteFor('sales_remote'), { role: 'staff', functions: ['sales'], work_mode: 'remote' });
  assert.deepEqual(inviteFor('sales_in_person'), { role: 'staff', functions: ['sales'], work_mode: 'in_person' });
  assert.deepEqual(inviteFor('field'), { role: 'staff', functions: ['field'], field_function: 'driver_detailer', work_mode: null });
  assert.equal(HIRE_FUNCTIONS.length, 6);
});

test('the Hire form\'s pay goes into the agreement', () => {
  const remote = [{ key: 'pay_basis', label: 'Pay', value: 'monthly' }, { key: 'rate', label: 'Rate', value: '350.00' }, { key: 'currency', label: 'Currency', value: 'USD' }, { key: 'start', label: 'Start Date', value: 'November 10, 2026' }];
  assert.deepEqual(agreementValues(remote, { pay_basis: 'monthly', pay_cents: 42500, pay_currency: 'USD' }), { pay_basis: 'monthly', rate: '425.00', currency: 'USD', start: 'November 10, 2026' });
  assert.equal(agreementValues(remote, { pay_basis: 'commission', pay_cents: null, pay_currency: null }).rate, '350.00');
  const field = [{ key: 'wage', label: 'Hourly Wage (CA$)', value: '18.00' }, { key: 'address', label: 'Home address', value: '' }];
  assert.deepEqual(agreementValues(field, { pay_basis: 'hourly', pay_cents: 1950, pay_currency: 'CAD' }), { wage: '19.50', address: '' });
  assert.deepEqual(agreementValues(field, null), { wage: '18.00', address: '' });
});

test('typed pay as cents', () => {
  assert.equal(payCents('425'), 42500);
  assert.equal(payCents('$1,250.50'), 125050);
  assert.equal(payCents('0'), null);
  assert.equal(payCents('abc'), null);
});
