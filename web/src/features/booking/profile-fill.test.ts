import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addressWords, driverRow, driversToOffer, fillFromProfile, licenceWords, profileFlags, type RenterProfile } from './profile-fill.ts';

const empty = () => ({ car: '', from: '', to: '', tf: '10:00', tt: '10:00', pickupAt: 'ours', pickupAddress: { label: '', placeId: '' }, pickupAirport: '', returnAt: 'ours',
  returnAddress: { label: '', placeId: '' }, returnAirport: '', first: '', last: '', email: '', phone: '', dobY: '', dobM: '', dobD: '', drivers: [], referrer: '', heardAbout: '',
  licClass: '', licIssuer: '', coverage: '', coverageCard: '', coverageCardAck: false, opcfAck: false, bookingType: 'standard', winter: false, babySeats: 0, notes: '', addons: [],
  agree: false, marketing: false, notifyChannel: '', promo: '' }) as never as Parameters<typeof fillFromProfile>[0];
const profile = (over: Partial<RenterProfile> = {}): RenterProfile => ({
  renter_id: 'r1', legal_name: 'Mary Ann Test', first: 'Mary Ann', last: 'Test', date_of_birth: '1990-05-05', email: 'm@example.test', mobile: '6475550100', notify_channel: 'text',
  address: { line1: '1 Test Street', line2: null, city: 'Toronto', province: 'ON', postal_code: 'M1M 1M1', country: 'CA', updated_at: '2026-01-01T00:00:00Z' },
  licence: { class: 'G', issuer: 'ON', expiry: '2030-01-01', number_end: '1234' },
  drivers: [{ full_name: 'Second Driver', first: 'Second', last: 'Driver', date_of_birth: '1992-02-02', email: 's@example.test', licence_class: 'G' }],
  stale: { licence_expired: false, address_old: false, address_max_months: 12 }, ...over });
const rules = { licenceClasses: ['G', 'G2'], otherLicence: true };

test('the profile fills the empty fields: name, date of birth, licence class, channel', () => {
  const { data, filled } = fillFromProfile(empty(), profile(), rules);
  assert.equal(`${data.first}|${data.last}|${data.dobY}-${data.dobM}-${data.dobD}|${data.licClass}|${data.notifyChannel}`, 'Mary Ann|Test|1990-5-5|G|text');
  assert.deepEqual(filled, ['first', 'last', 'dob', 'licClass', 'notifyChannel']);
});

test('what the person typed or a draft holds always wins', () => {
  const { data, filled } = fillFromProfile({ ...empty(), first: 'Mae', dobY: '1991', licClass: 'G2' }, profile(), rules);
  assert.equal(`${data.first}|${data.dobY}|${data.licClass}`, 'Mae|1991|G2');
  assert.ok(!filled.includes('first') && !filled.includes('dob') && !filled.includes('licClass'));
});

test('a licence from elsewhere is "other" with its issuer, when other licences are reviewed', () => {
  const p = profile({ licence: { class: 'C', issuer: 'Quebec', expiry: null, number_end: null } });
  assert.equal(fillFromProfile(empty(), p, rules).data.licIssuer, 'Quebec');
  assert.equal(fillFromProfile(empty(), p, { ...rules, otherLicence: false }).data.licClass, '');
});

test('the drivers on file are offered, not added (each may add a fee), and not twice', () => {
  assert.equal(driversToOffer(empty(), profile()).length, 1);
  const row = driverRow(profile().drivers[0]!);
  assert.equal(`${row.first} ${row.last} ${row.dobY}-${row.dobM}-${row.dobD} ${row.email}`, 'Second Driver 1992-2-2 s@example.test');
  assert.equal(driversToOffer({ ...empty(), drivers: [row] }, profile()).length, 0);
});

test('out of date: an expired licence, one that expires before the return, an old address', () => {
  assert.deepEqual(profileFlags(profile(), { todayIso: '2026-11-13' }), []);
  assert.match(profileFlags(profile({ licence: { class: 'G', issuer: 'ON', expiry: '2026-11-01', number_end: '1234' } }), { todayIso: '2026-11-13' })[0]!.message, /expired on November 1, 2026/);
  assert.match(profileFlags(profile({ licence: { class: 'G', issuer: 'ON', expiry: '2026-12-01', number_end: '1234' } }), { todayIso: '2026-11-13', returnIso: '2026-12-05' })[0]!.message, /before the return/);
  assert.match(profileFlags(profile({ stale: { licence_expired: false, address_old: true, address_max_months: 12 } }), { todayIso: '2026-11-13' })[0]!.message, /over 12 months/);
  assert.match(profileFlags(profile({ stale: { licence_expired: true, address_old: false, address_max_months: 12 } }), { todayIso: '2026-11-13', staff: true })[0]!.message, /^The renter's licence .*Ask them/);
});

test('the licence and the address in words (the number whole only for staff)', () => {
  assert.equal(licenceWords(profile().licence), 'Class G, ON, ending 1234, expires January 1, 2030');
  assert.equal(licenceWords({ ...profile().licence!, number: 'T1234-5678' }, true), 'Class G, ON, T1234-5678, expires January 1, 2030');
  assert.equal(addressWords(profile().address), '1 Test Street, Toronto, ON, M1M 1M1');
});
