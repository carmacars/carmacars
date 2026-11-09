// The digital incident card (1150): what /incident shows.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { digitalView, incidentDocHref, incidentHref, incidentRedirect, proofWords, type DigitalCard, type IncidentDigital } from './digital.ts';

const company = { trade_name: 'CarmaCars', support_phone: '647-555-0100', roadside_phone: null, incident_line: null };
const row = (n: string) => ({ booking_number: n, pickup_at: '2026-11-09T14:00:00Z', return_at: '2026-11-12T14:00:00Z', status: 'on_rent', car: '2024 Kia K5', plate: 'TEST 1', role: 'renter' as const });
const card = (kind: DigitalCard['coverage']['kind'], proof = false): DigitalCard => ({
  booking_id: 'b', booking_number: 'CC-1', pickup_at: '2026-11-09T14:00:00Z', return_at: '2026-11-12T14:00:00Z', renter: 'Pat Example', company,
  car: { vehicle_id: 'v', year: 2024, make: 'Kia', model: 'K5', plate: 'TEST 1', vin: null },
  coverage: { kind, option: null, confirmed: true, insurer_name: null, policy_number: null, policy_expiry: null, card_issuer: null, card_brand: null, card_last4: null,
    card_coverage_provider: null, cardholder_name: null, plan_provider: null, plan_policy_number: null, plan_claims_phone: null, plan_reference: null, proof_document_id: proof ? 'd' : null },
  status: 'on_rent', role: 'renter', drivers: [{ name: 'Pat Example', role: 'renter' }, { name: 'Sam Example', role: 'additional' }],
  contract: { document_id: 'c', title: 'Signed rental agreement', created_at: '2026-11-08T00:00:00Z' }, proof: proof ? { document_id: 'd', mime: 'image/jpeg' } : null });

test('no booking in progress: the steps and the numbers only, nothing about a booking', () => {
  const v = digitalView({ company, bookings: [], card: null });
  assert.equal(v.mode, 'none');
  assert.ok(v.steps.includes('Call or text CarmaCars support: 647-555-0100.'));
  assert.ok(!('card' in v) && !('bookings' in v));
});

test('several bookings in progress and none chosen: a picker of their own bookings', () => {
  const v = digitalView({ company, bookings: [row('CC-1'), row('CC-2')], card: null });
  assert.equal(v.mode, 'pick');
  assert.deepEqual(v.mode === 'pick' && v.bookings.map((b) => b.booking_number), ['CC-1', 'CC-2']);
});

test('the chosen (or only) booking: its card, with the other bookings to switch to', () => {
  const d: IncidentDigital = { company, bookings: [row('CC-1'), row('CC-2')], card: card('own_policy', true) };
  const v = digitalView(d);
  assert.equal(v.mode, 'card');
  assert.deepEqual(v.mode === 'card' && v.others.map((b) => b.booking_number), ['CC-2']);
});

test('what to show for each option', () => {
  assert.match(proofWords(card('own_policy', true)), /own insurance pink slip \(below\)/);
  assert.match(proofWords(card('card')), /card you paid with/);
  assert.match(proofWords(card('plan')), /Protection Plan provider/);
  assert.match(proofWords(card('none')), /call us before you drive/);
});

test('the links: the portal page, one booking, a document; /incident keeps only a valid booking number', () => {
  assert.equal(incidentHref(), '/account/incident');
  assert.equal(incidentHref('CC-1'), '/account/incident?b=CC-1');
  assert.equal(incidentDocHref('abc'), '/account/incident/doc/abc');
  assert.equal(incidentRedirect(null), '/account/incident');
  assert.equal(incidentRedirect('cc-12'), '/account/incident?b=CC-12');
  assert.equal(incidentRedirect('https://evil.example/x'), '/account/incident');
});
