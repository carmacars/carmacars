import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clockProblem, elapsed, emptyDraft, firstProblem, reportPayload, sections, type Draft, type JobFacts } from './field.ts';
import { heldMessage, holdsSales, homeTab, portalPath, tabsFor } from './roles.ts';
import type { Roles } from '../shared.ts';

const SHOTS = [{ seq: 1, shot: 'front', guide: null }, { seq: 2, shot: 'rear', guide: null }, { seq: 3, shot: 'odometer', guide: null }, { seq: 4, shot: 'fuel_gauge', guide: null }];
const pickup: JobFacts = { kind: 'pickup', shots: SHOTS, unattended: false, detailsLater: false, odometerOutKm: null };
const ret: JobFacts = { kind: 'return', shots: SHOTS, unattended: false, detailsLater: false, odometerOutKm: 42_000 };
const done = (o: Partial<Draft> = {}): Draft => ({ ...emptyDraft(), odometer_km: '42,180', fuel_pct: 88, keys_count: 2, cleanliness: 'clean', licence_seen: true, card_seen: true,
  renter_signature_ref: 'bookings/b/pickup/signature_renter-1.png', staff_signature_ref: 'bookings/b/pickup/signature_staff-1.png', shotsDone: SHOTS.map((s) => s.shot), ...o });

test('handover: a pickup needs every photo, the readings, the licence and card checks, and both signatures', () => {
  const start = sections(pickup, emptyDraft());
  assert.deepEqual(start.map((s) => [s.key, s.done]), [['photos', false], ['readings', false], ['damage', true], ['checks', false], ['signatures', false]]);
  assert.equal(firstProblem(pickup, emptyDraft()), '4 photos to take: Front, Rear, Odometer…');
  assert.equal(firstProblem(pickup, done()), null);
  assert.equal(firstProblem(pickup, done({ shotsDone: ['front', 'rear', 'odometer'] })), '1 photo to take: Fuel gauge');
  assert.equal(firstProblem(pickup, done({ odometer_km: '42.5' })), 'Enter the odometer in whole kilometres.');
  assert.equal(firstProblem(pickup, done({ fuel_pct: null })), 'Pick the fuel level.');
  assert.equal(firstProblem(pickup, done({ licence_seen: false })), 'Check the driver\'s licence.');
  assert.equal(firstProblem(pickup, done({ renter_signature_ref: null })), 'The renter signs.');
  assert.equal(firstProblem(pickup, done({ staff_signature_ref: null })), 'Sign as CarmaCars staff.');
});

test('handover: an unattended pickup asks for no renter signature and no licence check', () => {
  const j = { ...pickup, unattended: true };
  assert.equal(sections(j, emptyDraft()).some((s) => s.key === 'checks'), false);
  assert.equal(firstProblem(j, done({ renter_signature_ref: null, licence_seen: false, card_seen: false })), null);
  assert.equal(reportPayload(j, done()).renter_present, false);
});

test('handover: a return checks the odometer against the pickup, and takes "would not sign" with a reason', () => {
  assert.equal(firstProblem(ret, done({ odometer_km: '41900' })), 'The odometer is lower than at pickup (42,000 km). Check it.');
  assert.equal(firstProblem(ret, done({ renter_signature_ref: null })), 'The renter signs, or say why not.');
  assert.equal(firstProblem(ret, done({ renter_signature_ref: null, renter_declined_to_sign: true, renter_decline_reason: ' ' })), 'The renter signs, or say why not.');
  assert.equal(firstProblem(ret, done({ renter_signature_ref: null, renter_declined_to_sign: true, renter_decline_reason: 'Left before the walk-around' })), null);
  assert.equal(firstProblem(ret, done({ renter_signature_ref: null, renter_present: false })), null);
});

test('handover: damage needs where and what; what is sent has numbers, no blanks', () => {
  const dmg = { label: '', location: 'rear bumper', description: '', kind: 'scratch', size_cm: 4, position: null, is_new: true };
  assert.equal(firstProblem(ret, done({ damages: [dmg] })), 'Damage 1: say where it is and describe it.');
  const p = reportPayload(pickup, done({ damages: [{ ...dmg, description: '4 cm scratch, left of the plate' }], notes: '  ' }));
  assert.equal(p.odometer_km, 42180);
  assert.equal(p.fuel_or_charge_ok, true);
  assert.equal('notes' in p, false);
  assert.equal((p.damages as unknown[]).length, 1);
  assert.equal(reportPayload(pickup, done({ fuel_pct: 50 })).fuel_or_charge_ok, false);
  assert.equal('fuel_or_charge_ok' in reportPayload(ret, done()), false);
});

test('handover: an interrupted job opens where it was left (the server\'s report fills the draft)', () => {
  const d = emptyDraft({ odometer_km: 42180, fuel_pct: 75, keys_count: 2, cleanliness: 'clean', photos: [{ shot: 'front' }, { shot: 'front' }, { shot: 'rear' }], damages: [{ location: 'hood', description: 'chip' }] }, { odometer_km: 1, fuel_pct: 1 });
  assert.equal(d.odometer_km, '42180');
  assert.deepEqual(d.shotsDone, ['front', 'rear']);
  assert.equal(d.damages[0]!.kind, 'other');
  assert.equal(emptyDraft(null, { odometer_km: 42000, fuel_pct: 100 }).odometer_km, '42000');
});

test('clock: the phone\'s location, or the reason it cannot give it', () => {
  assert.equal(clockProblem({ lat: 43.65, lng: -79.38, accuracy: 12, located_at: '2026-11-20T14:00:00Z' }, ''), null);
  assert.equal(clockProblem(null, 'no'), 'Location is off. Turn it on, or say why this phone cannot share it.');
  assert.equal(clockProblem(null, 'Underground garage, no signal'), null);
  assert.equal(elapsed('2026-11-20T14:00:00Z', Date.parse('2026-11-20T16:05:30Z')), '2 h 05 min');
});

// ---------------------------------------------------------------- roles
const roles = (o: Partial<Roles> = {}): Roles => ({ admin: false, va: null, field: false, owner: false, renter: false, investor: false, staff: false, two_step_required: false, name: null, ...o });
test('tabs: one app for every role, each person sees what their account holds', () => {
  assert.deepEqual(tabsFor(null), ['explore', 'profile']);
  assert.deepEqual(tabsFor(roles({ renter: true })), ['explore', 'trips', 'profile']);
  assert.deepEqual(tabsFor(roles()), ['explore', 'trips', 'profile']);
  assert.deepEqual(tabsFor(roles({ field: true, staff: true })), ['field', 'explore', 'profile']);
  assert.deepEqual(tabsFor(roles({ va: 'sales', staff: true })), ['leads', 'explore', 'profile']);
  assert.deepEqual(tabsFor(roles({ owner: true, renter: true })), ['owner', 'explore', 'trips', 'profile']);
  assert.deepEqual(tabsFor(roles({ field: true, staff: true, va_functions: ['sales'] })), ['field', 'leads', 'explore', 'profile']);
  assert.equal(homeTab(roles({ field: true, staff: true })), 'field');
  assert.equal(homeTab(roles({ renter: true })), 'explore');
});
test('tabs: Finance and Fleet staff have no leads; staff who are held have no work tabs and are told why', () => {
  assert.equal(holdsSales(roles({ va: 'finance', staff: true, va_functions: ['finance', 'fleet'] })), false);
  assert.equal(holdsSales(roles({ va: 'finance', staff: true, va_functions: ['finance', 'cs'] })), true);
  assert.deepEqual(tabsFor(roles({ field: true, staff: true, onboarding_locked: true })), ['explore', 'profile']);
  assert.match(heldMessage(roles({ field: true, staff: true, onboarding_locked: true }))!, /onboarding/);
  assert.match(heldMessage(roles({ field: true, staff: true, inactive_locked: true }))!, /locked/);
  assert.equal(heldMessage(roles({ renter: true })), null);
});
test('the long tail opens on the site: the Admin portal for an Admin, the staff portal for staff, none for a renter', () => {
  assert.equal(portalPath(roles({ admin: true, staff: true })), '/admin');
  assert.equal(portalPath(roles({ va: 'finance', staff: true })), '/staff');
  assert.equal(portalPath(roles({ investor: true })), '/investor');
  assert.equal(portalPath(roles({ renter: true })), null);
});
