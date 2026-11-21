import { test } from 'node:test';
import assert from 'node:assert/strict';
import { afterReport, canSwitchOff, decide, distanceM, needsPolicy, permissionLine, policyBody, prefsBody, qualifies, reportBody, shouldSend, type Fix, type Perms } from './location.ts';
import type { MyLocation } from '../shared.ts';

const ALL: Perms = { foreground: 'granted', background: 'granted' };
const FG: Perms = { foreground: 'granted', background: 'denied' };
const NONE: Perms = { foreground: 'undetermined', background: 'undetermined' };
const POLICY = { version: 'v1', text: 'Policy', accepted_at: '2026-11-01T12:00:00Z' };
const staff = (o: Partial<MyLocation> = {}): MyLocation => ({ kind: 'staff', role: 'field', share: true, why: 'shift', sharing_on: true, locked: false, on_shift: true, field_job_id: null, reason: 'shift', policy: POLICY, ...o });
const renter = (o: Partial<MyLocation> = {}): MyLocation => ({ kind: 'renter', role: 'renter', share: true, why: 'pickup', sharing_on: true, locked: false, booking_id: 'b1', reason: 'pickup', ...o });

test('staff: shared on shift or on a job, never off duty', () => {
  assert.deepEqual(decide(staff(), ALL, true), { mode: 'background', why: 'share' });
  assert.deepEqual(decide(staff({ on_shift: false, reason: 'job', field_job_id: 'j1', locked: true, why: 'job' }), ALL, true).mode, 'background');
  // off duty: the server says share false; even a stale client-side on_shift never shares without the server
  assert.deepEqual(decide(staff({ share: false, on_shift: false, reason: null, why: 'off_duty' }), ALL, true), { mode: 'off', why: 'not_now' });
  assert.equal(qualifies(staff({ on_shift: false, reason: null })), false);
});

test('staff: nothing before the electronic monitoring policy is accepted', () => {
  const s = staff({ policy: { ...POLICY, accepted_at: null }, why: 'policy' });
  assert.equal(needsPolicy(s), true);
  assert.deepEqual(decide(s, ALL, true), { mode: 'off', why: 'policy' });
  assert.equal(needsPolicy(staff()), false);
});

test('staff: the switch off stops sharing on shift, but not during an active job, which cannot be switched off', () => {
  assert.deepEqual(decide(staff({ sharing_on: false, share: false, why: 'off' }), ALL, true), { mode: 'off', why: 'off' });
  const job = staff({ sharing_on: false, locked: true, field_job_id: 'j1', reason: 'job', why: 'job' });
  assert.equal(decide(job, ALL, true).mode, 'background');
  assert.equal(canSwitchOff(job), false);
  assert.equal(canSwitchOff(staff()), true);
  assert.equal(canSwitchOff(renter()), true);
});

test('staff: without "Always" only while the app is open; without any permission nothing', () => {
  assert.equal(decide(staff(), FG, true).mode, 'foreground');
  assert.deepEqual(decide(staff(), NONE, true), { mode: 'off', why: 'permission' });
  assert.match(permissionLine(staff(), FG), /Always/);
  assert.equal(permissionLine(staff(), ALL), '');
});

test('renters and owners: only around a pickup or return, only with permission, never in the background', () => {
  assert.deepEqual(decide(renter(), ALL, true), { mode: 'foreground', why: 'share' });
  assert.equal(decide(renter({ kind: 'owner', role: 'owner', reason: 'return', why: 'return' }), ALL, true).mode, 'foreground');
  assert.deepEqual(decide(renter({ share: false, booking_id: null, reason: null, why: 'no_booking' }), ALL, true), { mode: 'off', why: 'not_now' });
  assert.deepEqual(decide(renter({ sharing_on: false, share: false, why: 'off' }), ALL, true), { mode: 'off', why: 'off' });
  assert.deepEqual(decide(renter(), NONE, true), { mode: 'off', why: 'permission' });
  assert.equal(permissionLine(renter(), FG), '');
  assert.match(permissionLine(renter(), { foreground: 'denied', background: 'denied' }), /phone's settings/);
});

test('signed out, no account or an unknown state: nothing', () => {
  assert.deepEqual(decide(staff(), ALL, false), { mode: 'off', why: 'signed_out' });
  assert.deepEqual(decide(null, ALL, true), { mode: 'off', why: 'unknown' });
  assert.deepEqual(decide({ share: false, kind: null, why: 'none' }, ALL, true), { mode: 'off', why: 'unknown' });
});

test('throttle: the first good fix at once, then every 30 seconds while moving, none while still', () => {
  const t0 = Date.parse('2026-11-20T15:00:00Z');
  const at = (lat: number, s: number, o: Partial<Fix> = {}): Fix => ({ lat, lng: -79.38, accuracy: 10, at: t0 + s * 1000, ...o });
  assert.equal(shouldSend(null, at(43.65, 0), t0), true);
  assert.equal(shouldSend(null, at(43.65, 0, { accuracy: 9000 }), t0), false, 'a fix too rough is never sent');
  assert.equal(shouldSend(null, at(43.65, -300), t0), false, 'an old fix is never sent');
  const last = { fix: at(43.65, 0), at: t0 };
  assert.equal(shouldSend(last, at(43.652, 10), t0 + 10_000), false, 'not within 30 seconds');
  assert.equal(shouldSend(last, at(43.652, 31), t0 + 31_000), true, 'about 220 m in 31 s: moving');
  assert.equal(shouldSend(last, at(43.65005, 90), t0 + 90_000), false, 'about 5 m: still');
  assert.equal(shouldSend(last, at(43.65005, 90, { speed: 8 }), t0 + 90_000), true, 'the phone says it is moving');
  assert.equal(shouldSend(last, at(43.6502, 60, { accuracy: 100 }), t0 + 60_000), false, 'within the fix\'s own accuracy: still');
});

test('reports: the server no longer keeping it stops and asks again; signed out stops; busy keeps', () => {
  assert.equal(afterReport({ ok: true, data: { stored: true } }), 'keep');
  assert.equal(afterReport({ ok: true, data: { stored: false, why: 'soon' } }), 'keep');
  assert.equal(afterReport({ ok: true, data: { stored: false, why: 'stale' } }), 'keep');
  assert.equal(afterReport({ ok: true, data: { stored: false, why: 'off_duty' } }), 'recheck');
  assert.equal(afterReport({ ok: true, data: { stored: false, why: 'no_booking' } }), 'recheck');
  assert.equal(afterReport({ ok: false, code: 'auth' }), 'stop');
  assert.equal(afterReport({ ok: false, code: 'offline' }), 'keep');
  assert.deepEqual(reportBody({ lat: 43.6532261, lng: -79.3831843, accuracy: 12.6, at: Date.parse('2026-11-20T15:00:00Z') }),
    { action: 'report', lat: 43.653226, lng: -79.383184, accuracy_m: 13, at: '2026-11-20T15:00:00.000Z', sharing_on: undefined, version: undefined });
  assert.equal(prefsBody(false).sharing_on, false);
  assert.equal(policyBody('v2').version, 'v2');
  assert.ok(Math.abs(distanceM({ lat: 43.65, lng: -79.38 }, { lat: 43.66, lng: -79.38 }) - 1112) < 5);
});
