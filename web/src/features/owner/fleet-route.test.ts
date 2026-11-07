import { test } from 'node:test';
import assert from 'node:assert/strict';
import { blankOwner, blankVehicle, fleetVehiclePayload, isFleet, ownerErrors, vehicleErrors, type ApplyVehicle } from './apply-schema.ts';
import { fillPdf, readFields, sampleForm } from '../official-forms/fill.ts';

// The fleet supplier route (migration 0710): what the application asks, what it sends, and the forms filled for a car.
const corp = { ...blankOwner(), owner_type: 'corporation' as const, route: 'fleet_supplier' as const, first_name: 'Nora', last_name: 'Example', corporation_name: 'Northshore Holdings Ltd.',
  corporation_number: '1000001', signing_officer_name: 'Nora Example', signing_officer_title: 'Director', address_line1: '1 Example Way', city: 'Toronto', postal_code: 'M5V 1A1',
  email: 'q33-north@example.test', phone: '647-555-0142' };
const car = (p: Partial<ApplyVehicle> = {}): ApplyVehicle => ({ ...blankVehicle('k'), vin: '1HGCM82633A133001', year: '2021', make: 'Toyota', model: 'Camry', plate: 'Q33A',
  lease_tier: 'regular', fleet_transfer: { registered_to: 'corporation', name: '', address: '', date: '' }, ...p });

test('the route is for a corporation, with its number and signing officer; no licence or date of birth', () => {
  assert.ok(isFleet(corp));
  assert.deepEqual(ownerErrors(corp), {});
  assert.ok(ownerErrors({ ...corp, owner_type: 'individual' }).owner_type);
  assert.ok(ownerErrors({ ...corp, corporation_number: '' }).corporation_number);
  assert.ok(ownerErrors({ ...corp, signing_officer_title: '' }).signing_officer_title);
});

test('a car: the VIN, the plate, the tier and who it is registered to; nothing from the other routes', () => {
  assert.deepEqual(vehicleErrors(car(), 'corporation', true), {});
  assert.ok(vehicleErrors(car({ lease_tier: '' }), 'corporation', true).lease_tier);
  assert.ok(vehicleErrors(car({ plate: '' }), 'corporation', true).plate);
  assert.ok(vehicleErrors(car({ fleet_transfer: undefined }), 'corporation', true).registered_to);
  const moving = vehicleErrors(car({ fleet_transfer: { registered_to: 'seller', name: '', address: '', date: '' } }), 'corporation', true);
  assert.deepEqual(Object.keys(moving).sort(), ['transfer_address', 'transfer_date', 'transfer_name']);
  // the standard route still asks the colour, insurer and the rest
  assert.ok(vehicleErrors(car(), 'corporation').current_insurer);
});

test('the payload carries the tier and the transfer, and none of the other routes\' answers', () => {
  const p = fleetVehiclePayload(car({ fleet_transfer: { registered_to: 'officer', name: ' Nora Example ', address: '1 Example Way, Toronto', date: '2026-11-01' } }));
  assert.equal(p.lease_tier, 'regular');
  assert.deepEqual(p.fleet_transfer, { registered_to: 'officer', name: 'Nora Example', address: '1 Example Way, Toronto', date: '2026-11-01' });
  assert.ok(!('onboarding_method' in p) && !('title_status' in p) && !('management_mode' in p));
  assert.deepEqual(fleetVehiclePayload(car()).fleet_transfer, { registered_to: 'corporation' });
});

test('a transfer form for the car: only the empty text boxes are filled, the signature is left for ink', async () => {
  const src = await sampleForm();
  const out = await fillPdf(src, { owner_name: 'NORTHSHORE HOLDINGS LTD.', vin: '1HGCM82633A133001', plate: 'Q33A', postal_code: 'M5V 1A1', owner_signature: null },
    { owner_name: 'corporation.registry_name', vin: 'vehicle.vin', plate: 'vehicle.plate', postal_code: 'owner.postal_code', owner_signature: { type: 'signature' } });
  assert.deepEqual([...out.filled].sort(), ['owner_name', 'plate', 'postal_code', 'vin']);
  assert.ok(out.byHand.includes('owner_signature'));
  // the publisher's bytes come first, unchanged (an incremental update)
  assert.deepEqual(out.bytes.slice(0, src.length), src);
  const read = await readFields(out.bytes);
  assert.ok(read.fields.some((f) => f.name === 'vin'));
});
