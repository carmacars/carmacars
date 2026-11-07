import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ADMIN, STAFF_SHARED, bookingCan, bookingTabs, listingCan, portalBase, staffViewer, vehicleCan, type BookingCan, type StaffFn } from './viewer.ts';

// r31 "Simple": the shared Admin and staff pages. These tables are what each staff function saw on its own copy of the
// page before r31 (app/staff/bookings/[number], vehicles/[id], listings/[id] at 2a7ed386); a change here is a change of
// who sees what, so it is spelled out per function.
const FNS: StaffFn[] = ['sales', 'cs', 'fleet', 'finance'];
const SRC = fileURLToPath(new URL('../../', import.meta.url));

const yes = (c: BookingCan) => Object.entries(c).filter(([, v]) => v).map(([k]) => k).sort();

describe('the shared booking page', () => {
  it('gives an Admin every section and every button', () => {
    const c = bookingCan(ADMIN);
    for (const [k, v] of Object.entries(c)) {
      if (['scheduleJob', 'latePanel', 'photoReview', 'licenceReview', 'staffUpload', 'refundApprove'].includes(k)) continue; // staff-only shapes of what an Admin does elsewhere on the page
      assert.equal(v, true, `admin: ${k}`);
    }
    assert.deepEqual(bookingTabs(ADMIN), ['overview', 'money', 'documents', 'car', 'activity', 'extras']);
  });
  it('gives each staff function exactly what its own copy showed', () => {
    const want: Record<StaffFn, string[]> = {
      sales: ['handover', 'inbox', 'licenceReview', 'money', 'offer', 'sign', 'staffUpload'],
      cs: ['cancelForRenter', 'carLink', 'driverLinks', 'editOfferPending', 'extras', 'handover', 'inbox', 'latePanel', 'money', 'offer', 'paperSignatures', 'sign', 'staffUpload'],
      fleet: ['carLink', 'handover', 'latePanel', 'photoReview', 'scheduleJob', 'sign', 'staffUpload'],
      finance: ['agreementMoney', 'manualPayments', 'money', 'refund', 'refundApprove', 'settleDeposit', 'staffUpload', 'statement']
    };
    for (const fn of FNS) assert.deepEqual(yes(bookingCan(staffViewer(fn))), want[fn].sort(), fn);
  });
  it('never gives a staff function the Admin-only parts', () => {
    for (const fn of FNS) {
      const c = bookingCan(staffViewer(fn));
      assert.equal(c.admin, false, fn);
      assert.equal(c.voidRecords, false, `${fn}: only an Admin voids a payment or a paper signature`);
      assert.equal(c.renterDocs, false, `${fn}: the coverage review stays with an Admin and customer service's own queue`);
      assert.equal(c.verifyInPerson, false, fn);
    }
  });
  it('shows the tabs each function had', () => {
    assert.deepEqual(bookingTabs(staffViewer('sales')), ['overview', 'money', 'documents', 'car', 'activity']);
    assert.deepEqual(bookingTabs(staffViewer('cs')), ['overview', 'money', 'documents', 'car', 'activity', 'extras']);
    assert.deepEqual(bookingTabs(staffViewer('fleet')), ['overview', 'documents', 'car', 'activity']);
    assert.deepEqual(bookingTabs(staffViewer('finance')), ['overview', 'money', 'documents', 'car', 'activity']);
  });
});

describe('the shared vehicle and listing pages', () => {
  it('opens the car to Fleet, customer service and Finance (maintenance only), not to Sales', () => {
    assert.equal(vehicleCan(staffViewer('sales')), null);
    assert.deepEqual(vehicleCan(staffViewer('finance')), { admin: false, maintenanceOnly: true, car: false, rates: false, maintenance: false, ownerHandoffs: false, publish: false });
    assert.deepEqual(vehicleCan(staffViewer('fleet')), { admin: false, maintenanceOnly: false, car: true, rates: true, maintenance: true, ownerHandoffs: true, publish: true });
    assert.deepEqual(vehicleCan(staffViewer('cs')), { admin: false, maintenanceOnly: false, car: true, rates: false, maintenance: false, ownerHandoffs: false, publish: true });
    assert.equal(vehicleCan(ADMIN)?.admin, true);
  });
  it('opens a listing to customer service and Fleet; Retry and Unlist stay with an Admin', () => {
    assert.equal(listingCan(staffViewer('sales')), null);
    assert.equal(listingCan(staffViewer('finance')), null);
    assert.deepEqual(listingCan(staffViewer('cs')), { admin: false, carLink: false, samplesNote: false });
    assert.deepEqual(listingCan(staffViewer('fleet')), { admin: false, carLink: true, samplesNote: false });
    assert.deepEqual(listingCan(ADMIN), { admin: true, carLink: true, samplesNote: true });
  });
  it('keeps the links in the portal the page is open in', () => {
    assert.equal(portalBase(ADMIN), '/admin');
    for (const fn of FNS) assert.equal(portalBase(staffViewer(fn)), '/staff');
  });
});

describe('the staff addresses of the shared pages', () => {
  it('render the shared component at both addresses, so every old staff link keeps working', () => {
    for (const [staff, { admin, shared }] of Object.entries(STAFF_SHARED)) {
      const name = shared.split('/').pop()!;
      for (const route of [staff, admin]) {
        const src = readFileSync(`${SRC}app${route}/page.tsx`, 'utf8');
        assert.match(src, new RegExp(`from '@/${shared}'`), `${route} imports ${shared}`);
        assert.match(src, new RegExp(`<${name} `), `${route} renders ${name}`);
      }
      assert.match(readFileSync(`${SRC}app${staff}/page.tsx`, 'utf8'), /staffCtx\(/, `${staff} reads through the staff door`);
      assert.match(readFileSync(`${SRC}app${admin}/page.tsx`, 'utf8'), /adminCtx\(/, `${admin} reads through the Admin door`);
    }
  });
});

describe('the vehicle page tabs', async () => {
  const { vehicleTabs, vehicleTab, tabForHash } = await import('../vehicle-page/tabs.ts');
  const keys = (v: Parameters<typeof vehicleCan>[0]) => vehicleTabs(vehicleCan(v)!).map(([k]) => k);
  it('gives staff the Admin\'s tabs their function uses', () => {
    assert.deepEqual(keys(ADMIN), ['overview', 'rates', 'calendar', 'listing', 'maintenance', 'records']);
    assert.deepEqual(keys(staffViewer('fleet')), ['overview', 'rates', 'listing', 'maintenance', 'records']);
    assert.deepEqual(keys(staffViewer('cs')), ['overview', 'listing', 'records']);
    assert.deepEqual(keys(staffViewer('finance')), ['maintenance']);
  });
  it('keeps the old addresses: ?tab=fees, ?record=1 and #maintenance', () => {
    const fleet = vehicleTabs(vehicleCan(staffViewer('fleet'))!);
    assert.equal(vehicleTab(fleet, 'fees', undefined), 'rates');
    assert.equal(vehicleTab(fleet, undefined, '1'), 'maintenance');
    assert.equal(vehicleTab(fleet, 'calendar', undefined), 'overview');
    assert.equal(tabForHash('#maintenance', fleet.map(([k]) => k)), 'maintenance');
    assert.equal(tabForHash('#maintenance', ['overview', 'listing', 'records']), null);
  });
});
