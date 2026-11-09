// The accident card of a booking (release 35, 0910): the coverage this booking uses, in the renter's words.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accidentSteps, coverageBlock, type AccidentCardData, type AccidentCoverage } from './model.ts';

const none: AccidentCoverage = { kind: 'none', option: null, confirmed: false, insurer_name: null, policy_number: null, policy_expiry: null, card_issuer: null, card_brand: null,
  card_last4: null, card_coverage_provider: null, cardholder_name: null, plan_provider: null, plan_policy_number: null, plan_claims_phone: null, plan_reference: null, proof_document_id: null };

test('OPCF 27: the renter\'s own insurer and policy number', () => {
  const b = coverageBlock({ ...none, kind: 'own_policy', insurer_name: 'Own Insurer Co', policy_number: 'P-1', policy_expiry: '2027-06-01' });
  assert.match(b.title, /OPCF 27/);
  assert.deepEqual(b.rows, [['Insurer', 'Own Insurer Co'], ['Policy number', 'P-1'], ['Policy expires', '2027-06-01']]);
});

test('card coverage: the card and its coverage provider', () => {
  const b = coverageBlock({ ...none, kind: 'card', card_brand: 'Visa', card_last4: '4242', card_coverage_provider: 'Card Coverage Ltd' });
  assert.deepEqual(b.rows, [['Card', 'Visa ending 4242'], ['Coverage provider', 'Card Coverage Ltd']]);
});

test('the Protection Plan: the provider, the renter\'s own policy number and the claim page (1010)', () => {
  const b = coverageBlock({ ...none, kind: 'plan', plan_provider: 'RentalCover', plan_policy_number: 'RC-1', plan_claims_phone: null, plan_reference: 'ACT-9', plan_claim_url: 'https://www.rentalcover.com/en-us/claim/start' });
  assert.deepEqual(b.rows, [['Provider', 'RentalCover'], ['Your policy number', 'RC-1'], ['Claim page', 'https://www.rentalcover.com/en-us/claim/start']]);
  assert.match(b.lead, /claim page/);
  const r = coverageBlock({ ...none, kind: 'plan', plan_provider: 'RentalCover', plan_reference: 'ACT-9' });
  assert.deepEqual(r.rows[1], ['Your policy number', 'ACT-9']);
});

test('no coverage: the card says to call before driving; the steps are the car card\'s', () => {
  assert.equal(coverageBlock(none).rows.length, 0);
  const d = { company: { trade_name: 'CarmaCars', support_phone: '555-0100', roadside_phone: null, incident_line: null } } as unknown as AccidentCardData;
  assert.ok(accidentSteps(d).some((s) => s.includes('555-0100')));
});
