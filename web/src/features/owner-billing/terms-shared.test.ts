// Owner terms per car (0135): the words the Admin table and the owner portal show for a car's terms.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fmtDay, m, pc, sinceLine, stateLine, type CarTermsRow } from './terms-shared.ts';

const car = (over: Partial<CarTermsRow>): CarTermsRow => ({
  vehicle_id: 'v', name: 'Honda CR-V', plate: 'ABC123', status: 'available', onboarding_status: 'enrolled', supply_type: 'program_owner', shareholder: false,
  state: 'signed', enrolled: true, schedule_number: 'VS-1001', signed_at: '2026-09-01T16:00:00Z', mode: 'managed', method: 'transfer',
  current: { insurance_fee_cents: 45000, tracker_fee_cents: 2500, revenue_share_bps: 3500, install_fee_cents: 10000 }, since: '2026-09-01',
  scheduled: [], periods: [], changes: [], awaiting: null, ...over
});

test('amounts: dollars to the cent and the management fee in %', () => {
  assert.equal(m(45000), '$450.00');
  assert.equal(m(null), '');
  assert.equal(pc(3500), '35%');
  assert.equal(pc(2750), '27.5%');
  assert.equal(fmtDay('2026-10-24'), 'Oct 24, 2026');
});

test('state: signed with its schedule; not signed yet; not approved; a shareholder car', () => {
  assert.equal(stateLine(car({})), 'Signed VS-1001, Sep 1, 2026');
  assert.equal(stateLine(car({ state: 'pending', signed_at: null })), 'VS-1001 not signed yet');
  assert.equal(stateLine(car({ state: 'not_set', schedule_number: null })), 'Not approved yet');
  assert.equal(stateLine(car({ state: 'fixed', shareholder: true })), 'Shareholder: 90/10, no fees');
});

test('since: the date the terms in force started, or when they will start', () => {
  assert.equal(sinceLine(car({})), 'Sep 1, 2026');
  assert.equal(sinceLine(car({ since: null })), 'From the Enrollment Date');
  assert.equal(sinceLine(car({ state: 'pending' })), 'Once signed');
  assert.equal(sinceLine(car({ state: 'not_set' })), 'Once approved and signed');
});
