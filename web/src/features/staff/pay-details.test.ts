// Pay details (release 33): the form's checks.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkPayDetails } from './pay-details.ts';

test('a bank account needs the bank and the number', () => {
  assert.deepEqual(Object.keys(checkPayDetails({ method: 'bank_transfer', account_holder: 'Ana Example' })).sort(), ['account_no', 'bank_name']);
  assert.deepEqual(checkPayDetails({ method: 'bank_transfer', account_holder: 'Ana Example', bank_name: 'BDO', account_no: '0012 3456 7890' }), {});
  assert.ok(checkPayDetails({ method: 'bank_transfer', account_holder: 'Ana Example', institution_no: '12', account_no: '1234567' }).institution_no);
});

test('GCash takes a mobile number; PayPal, Wise and e-Transfer an email; OnlineJobs nothing more', () => {
  assert.deepEqual(checkPayDetails({ method: 'gcash', account_holder: 'Ana Example', account_no: '0917 123 4567' }), {});
  assert.ok(checkPayDetails({ method: 'gcash', account_holder: 'Ana Example', account_no: '12345' }).account_no);
  assert.ok(checkPayDetails({ method: 'paypal', account_holder: 'Ana Example', email: 'nope' }).email);
  assert.deepEqual(checkPayDetails({ method: 'wise', account_holder: 'Ana Example', email: 'ana@example.test' }), {});
  assert.deepEqual(checkPayDetails({ method: 'onlinejobs', account_holder: 'Ana Example' }), {});
});
