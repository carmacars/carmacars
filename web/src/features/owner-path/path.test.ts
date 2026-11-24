import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownerPath, type SignCar, type SignStatus } from './path.ts';

const car = (o: Partial<SignCar> = {}): SignCar => ({ vehicle_id: 'v1', name: '2021 Toyota Camry', plate: 'ABCD123', status: 'onboarding', onboarding_status: 'terms_set', tier: 'regular',
  schedule_number: 'VS-1', vehicle_number: 1, schedule_signed: false, scheduled: true, photos_done: false, approved: false, waiting_approval: false, delivered_on: null, delivered: false, gate: 'x', ...o });
const st = (o: Partial<SignStatus> = {}): SignStatus => ({ viewer: 'owner', owner_id: 'o1', name: 'Northshore Ltd.', email: 'n@example.test', has_login: true, fleet_supplier: true, sign_first: true,
  profile_missing: [], master: { id: 'a', title: 'Fleet Supplier Lease Agreement', number: 'EA-1', variant: 'fleet_lease', status: 'draft', signed_on: null },
  title_holding: { number: 'TA-2', status: 'draft' }, cars: [], missing: [], owner_missing: [], last_reminder_at: null, can_remind: false, ...o });

test('sign first: with no car, the current step is signing the agreement, with one button', () => {
  const p = ownerPath(st())!;
  assert.deepEqual(p.steps.map((s) => s.state), ['done', 'current', 'todo', 'todo', 'todo', 'todo']);
  assert.equal(p.current?.code, 'sign');
  assert.deepEqual(p.current?.action, { label: 'Read and sign', href: '/owner/sign' });
  assert.equal(p.steps.filter((s) => s.action).length, 1, 'one primary action');
  assert.match(p.current!.note, /EA-1 with the Title-Holding and Lease Agreement TA-2/);
});

test('a profile with something missing comes first and names it', () => {
  const p = ownerPath(st({ profile_missing: ['Street address', 'Signing officer title'], master: null, title_holding: null }))!;
  assert.equal(p.current?.code, 'profile');
  assert.equal(p.current?.note, 'Missing: Street address, Signing officer title.');
});

test('signed, no car yet: add the first car; a car on Schedule A to confirm: confirm it', () => {
  const signed = { master: { id: 'a', title: 'Fleet Supplier Lease Agreement', number: 'EA-1', variant: 'fleet_lease', status: 'signed' as const, signed_on: '2026-11-24' }, title_holding: { number: 'TA-2', status: 'signed' } };
  assert.equal(ownerPath(st(signed))!.current?.action?.href, '/list-your-car/apply');
  const p = ownerPath(st({ ...signed, cars: [car()] }))!;
  assert.equal(p.current?.code, 'cars');
  assert.equal(p.current?.action?.label, 'Confirm my cars');
  const q = ownerPath(st({ ...signed, cars: [car({ schedule_signed: true })] }))!;
  assert.equal(q.current?.code, 'photos');
  assert.equal(q.current?.action?.href, '/owner/vehicles/v1#photos');
  const r = ownerPath(st({ ...signed, cars: [car({ schedule_signed: true, photos_done: true })] }))!;
  assert.equal(r.current?.code, 'approved');
  assert.equal(r.current?.action, null, 'waiting on CarmaCars: no button');
  assert.equal(ownerPath(st({ ...signed, cars: [car({ schedule_signed: true, photos_done: true, approved: true, delivered: true })] }))!.current, null, 'all done');
});

test('sign first off: no path', () => assert.equal(ownerPath(st({ sign_first: false })), null));
