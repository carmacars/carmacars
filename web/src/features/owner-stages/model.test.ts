// The owner pipeline's wording (r50, 4511). npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { actionFor, columns, daysWords, fillScript, hrefFor, progressLine, uploadKinds, waitsOn, type Board, type Stage, type Track } from './model.ts';

const stage = (o: Partial<Stage>): Stage => ({ code: 'transfer', label: 'Ownership transfer', state: 'current', actor: 'owner', items: [], override: null, action: null, blockers: [],
  bring: null, where: null, where_url: null, expected: '30 to 60 minutes', call_script: 'Hi {{first_name}}', owner_text: 'Book', staff_text: 'Help', ...o });
const track = (stages: Stage[]): Track => ({ vehicle_id: 'v', name: '2021 Hyundai Sonata', plate: 'ABCD123', owner_id: 'o', owner_name: 'Pat', route: 'transfer', route_label: 'Transfer',
  method: 'transfer', stages, current: stages.find((s) => s.state === 'current') ?? null, stage: stages.find((s) => s.state === 'current')?.code ?? null,
  actor: stages.find((s) => s.state === 'current')?.actor ?? null, done: stages.filter((s) => s.state === 'done' || s.state === 'not_needed').length, total: stages.length,
  stage_since: null, days_in_stage: 2, last_nudge_at: null, nudges: 0, fees_payer: 'You pay', uvip_needed: true, ssc_needed: true, appointment_at: null, appointment_place: null });

test('the owner sees "Your turn" only on their own stage; staff see who it waits on', () => {
  assert.equal(waitsOn('owner', 'owner'), 'Your turn');
  assert.equal(waitsOn('fleet', 'owner'), 'With CarmaCars');
  assert.equal(waitsOn('owner', 'sales'), 'Waiting on the owner');
  assert.equal(waitsOn('fleet', 'staff'), 'Your turn (Fleet)');
  assert.equal(waitsOn('admin', 'admin'), 'Your turn (Admin)');
  assert.equal(waitsOn(null, 'admin'), 'Nothing waiting');
});

test('one action for the right person: the owner on their stage, staff a nudge, an Admin Fleet\'s step too, Sales never an Admin\'s', () => {
  const s = stage({ action: { owner: { label: 'Book a ServiceOntario appointment', op: 'appointment', href: 'https://x', external: true }, staff: { label: 'Help', op: 'appointment' } } });
  assert.equal(actionFor(s, 'owner')?.label, 'Book a ServiceOntario appointment');
  assert.equal(actionFor(s, 'sales')?.op, 'appointment');
  assert.equal(actionFor(stage({ state: 'todo', action: s.action }), 'owner'), null, 'a later stage has no action');
  const fleet = stage({ code: 'inspection', actor: 'fleet', action: { fleet: { label: 'Inspect', op: 'inspected' } } });
  assert.equal(actionFor(fleet, 'owner'), null, 'the owner has nothing to press on Fleet\'s stage');
  assert.equal(actionFor(fleet, 'admin')?.op, 'inspected');
  assert.equal(actionFor(fleet, 'staff')?.op, 'inspected');
  assert.equal(actionFor(fleet, 'sales'), null);
  const terms = stage({ code: 'terms', actor: 'admin', action: { admin: { label: 'Approve the terms', href: '/admin/applications/1' } } });
  assert.equal(actionFor(terms, 'sales'), null);
  assert.equal(actionFor(terms, 'admin')?.href, '/admin/applications/1');
});

test('links: {base} becomes the portal', () => {
  assert.equal(hrefFor('{base}/owners/1#ob-photos', '/staff'), '/staff/owners/1#ob-photos');
  assert.equal(hrefFor('/admin/listings', '/staff'), '/admin/listings');
  assert.equal(hrefFor(null, '/admin'), null);
});

test('the call script names the owner, the car, the agent and what is missing', () => {
  assert.equal(fillScript('Hi {{first_name}}, {{agent}} here about your {{car}}: {{missing}}.', { first_name: 'Pat', car: 'Sonata', agent: 'Darren', missing: 'the licence' }),
    'Hi Pat, Darren here about your Sonata: the licence.');
  assert.equal(fillScript('Hi {{first_name}} {{missing}}', { first_name: '', car: 'x', agent: '' }), 'Hi there a few documents');
});

test('days in stage and the progress line', () => {
  assert.equal(daysWords(0), 'today');
  assert.equal(daysWords(1), '1 day');
  assert.equal(daysWords(4), '4 days');
  const t = track([stage({ code: 'application', state: 'done' }), stage({ code: 'terms', state: 'done' }), stage({})]);
  assert.equal(progressLine(t, 'owner'), '2 of 3 done. Now: Ownership transfer, your turn.');
  assert.equal(progressLine(track([stage({ state: 'done' })]), 'admin'), 'All 1 steps done.');
});

test('the owner uploads what the route asks for: the documents, the UVIP and certificate, the new permit', () => {
  const t = track([stage({ code: 'documents', state: 'current', items: [{ label: 'Driver\'s licence', kind: 'owner_id', done: false }, { label: 'Ownership permit', kind: 'ownership_permit', done: true }] }),
    stage({ code: 'transfer', state: 'todo', items: [{ label: 'UVIP', kind: 'uvip', done: false }, { label: 'Appointment', done: false }] }), stage({ code: 'registration', state: 'todo' })]);
  assert.deepEqual(uploadKinds(t), ['owner_id', 'ownership_permit', 'uvip', 'new_registration']);
  assert.deepEqual(uploadKinds(null), []);
});

test('the board: one column a stage, Application only when a car is there', () => {
  const b: Board = { viewer: 'sales', stall_days: 3, agent: 'D', stages: [{ code: 'application', label: 'Application', call_script: '', expected: '' }, { code: 'documents', label: 'Documents uploaded', call_script: '', expected: '' }],
    cars: [{ vehicle_id: 'v', owner_id: 'o', owner_name: 'Pat', first_name: 'Pat', phone: null, email: null, car: 'Sonata', plate: null, route: 'transfer', route_label: 'Transfer', stage: 'documents',
      stage_label: 'Documents uploaded', actor: 'owner', days_in_stage: 4, stage_since: '2026-11-20', stalled: true, next_action: 'Upload', salesperson: 'D', last_nudge_at: null, nudges: 0, has_login: true }] };
  assert.deepEqual(columns(b).map((c) => `${c.code}:${c.cars.length}`), ['documents:1']);
});
