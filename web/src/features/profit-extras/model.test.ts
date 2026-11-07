// Kickbacks and repair costs (release 29, C2): the period of a page and the CSV.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { paidByLabel, period, toCsv, type Extras } from './model.ts';

test('the period comes from the page, else the database default', () => {
  assert.deepEqual(period({ from: '2026-10-01', to: '2026-10-31' }), { from: '2026-10-01', to: '2026-10-31' });
  assert.deepEqual(period({ from: 'yesterday', to: '' }), { from: null, to: null });
});

test('the CSV has the lines, the net, every kickback and repair cost, quoted where needed', () => {
  const x: Extras = { level: 'vehicle', id: 'v', from: '2026-01-01', to: '2026-11-06', kickback_cents: 125000, repair_cents: 40000, net_cents: 85000,
    lines: [{ line: 'Body shop kickback', kind: 'revenue', cents: 100000 }, { line: 'Tow kickback', kind: 'revenue', cents: 25000 }, { line: 'Repair costs', kind: 'cost', cents: 40000 }],
    by_car: [], kickbacks: [{ on_date: '2026-11-01', vehicle_id: 'v', car: '2022 Car', line: 'Body shop kickback', cents: 100000, invoice_number: 'PI-000001', partner: 'Shop, Inc.' }],
    repairs: [{ id: 'r', on_date: '2026-11-02', vehicle_id: 'v', car: '2022 Car', vendor: 'Garage', description: 'Bumper "front"', cents: 40000, tax_cents: 5200, paid_by: 'company', claim_number: 'CL-1001' }] };
  const lines = toCsv(x).trim().split('\r\n');
  assert.equal(lines.length, 1 + 3 + 1 + 1 + 1);
  assert.match(lines[4]!, /Net \(kickbacks less repair costs\),,850\.00/);
  assert.match(lines[5]!, /^Kickback,2026-11-01,2022 Car,Body shop kickback,,1000\.00,,,PI-000001,"Shop, Inc\.",$/);
  assert.match(lines[6]!, /^Repair cost,2026-11-02,2022 Car,Garage,"Bumper ""front""",400\.00,52\.00,CarmaCars,,,CL-1001$/);
  assert.equal(paidByLabel('insurer'), 'The insurer');
});
