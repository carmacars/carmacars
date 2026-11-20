import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chargeState, eventLabel, eventTone, feeLine, lotIssues, mapUrl, pathLabel, sealShort, sourceLabel, toldLine } from './events.ts';

const fees = { speeding_180: 50000, speeding_220: 100000, speeding_300: 250000, non_return: 100000, theft_recovery: 150000 };

test('an event in a few words, with its tone', () => {
  assert.equal(eventLabel({ kind: 'speeding', tier: 220 }), 'Speeding over 220 km/h');
  assert.equal(eventLabel({ kind: 'speeding', tier: null }), 'Over the speeding alert level');
  assert.equal(eventLabel({ kind: 'pound', tier: null }), 'At a pound');
  assert.equal(eventLabel({ kind: 'after_hours', tier: null }), 'Driving at night');
  assert.equal(eventTone({ kind: 'speeding', tier: null }), 'amber');
  assert.equal(eventTone({ kind: 'speeding', tier: 180 }), 'red');
  assert.equal(eventTone({ kind: 'tamper', tier: null }), 'red');
});

test('the charge in plain words: the settings\' amounts, never a constant', () => {
  assert.equal(feeLine({ kind: 'speeding', tier: 180, fee_cents: 50000, fee_code: 'speeding_180' }, fees), '$500 plus HST');
  assert.equal(feeLine({ kind: 'speeding', tier: 300, fee_cents: 275050, fee_code: 'speeding_300' }, fees), '$2,750.50 plus HST');
  assert.equal(feeLine({ kind: 'speeding', tier: null, fee_cents: null, fee_code: null }, fees), 'No set charge');
  assert.equal(feeLine({ kind: 'pound', tier: null, fee_cents: 100000, fee_code: 'non_return_fee' }, fees), 'Recovery costs at cost; $1,000 non-return or $1,500 theft recovery');
  assert.equal(feeLine({ kind: 'harsh_driving', tier: null, fee_cents: null, fee_code: null }, fees), 'No set charge');
});

test('the state of the charge', () => {
  const base = { chargeable: false, line: null, kind: 'speeding' as const, booking_number: 'CC-1' };
  assert.equal(chargeState({ ...base, chargeable: true }), 'can_charge');
  assert.equal(chargeState({ ...base, line: { id: 'x', amount_cents: 50000, evidence_status: 'ok', on_statement: false } }), 'charged');
  assert.equal(chargeState({ ...base, line: { id: 'x', amount_cents: 50000, evidence_status: 'needs_evidence', on_statement: false } }), 'waiting_evidence');
  assert.equal(chargeState({ ...base, booking_number: null }), 'no_renter');
  assert.equal(chargeState({ ...base, kind: 'pound' }), 'pound');
  assert.equal(chargeState({ ...base, kind: 'harsh_driving' }), 'none');
});

test('the seal, the source, the map link and who was told', () => {
  assert.equal(sealShort('a'.repeat(58) + 'bcdef0'), 'aaaaaaaa…bcdef0');
  assert.equal(sealShort(null), 'not sealed yet');
  assert.equal(sourceLabel('device_event'), 'The tracker\'s own alarm');
  assert.equal(sourceLabel('new_kind'), 'new kind');
  assert.equal(mapUrl({ lat: 43.7, lng: -79.4 }), 'https://www.google.com/maps?q=43.7,-79.4');
  assert.equal(mapUrl({ lat: null, lng: -79.4 }), null);
  assert.equal(toldLine({ renter_notice_at: '2026-11-21T19:00:00Z', owner_notice_at: '2026-11-21T19:00:00Z' }), 'Staff, renter and owner');
  assert.equal(toldLine({ renter_notice_at: null, owner_notice_at: null }), 'Staff only');
});

test('a pound lot says what it still needs; the paths have their words', () => {
  assert.deepEqual(lotIssues({ latitude: null, longitude: null, checked: false, is_active: true, phone: '416-555-0100', hours: null }), ['No pin yet', 'Not checked', 'Hours missing']);
  assert.deepEqual(lotIssues({ latitude: 43.7, longitude: -79.4, checked: true, is_active: true, phone: '416-555-0100', hours: 'Open 24 hours' }), []);
  assert.deepEqual(lotIssues({ latitude: 43.7, longitude: -79.4, checked: true, is_active: false, phone: null, hours: null }), ['Off']);
  assert.equal(pathLabel('non_return'), 'Non-return charge and the recovery costs (10.6)');
  assert.equal(pathLabel(null), '');
});
