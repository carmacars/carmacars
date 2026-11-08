import { test } from 'node:test';
import assert from 'node:assert/strict';
import { otherUploads } from './doc-split.ts';

const drivers = [{ driver_id: 'd1' }, { driver_id: 'd2' }];
const up = (id: string, driver_id: string | null) => ({ id, driver_id, status: 'submitted' });

test('every upload of a driver on the booking is listed under that driver, none under Other documents', () => {
  assert.deepEqual(otherUploads([up('a', 'd1'), up('b', 'd2')], drivers), []);
});

test('an upload tied to nobody, or to a driver no longer on the booking, is listed under Other documents', () => {
  assert.deepEqual(otherUploads([up('a', 'd1'), up('b', null), up('c', 'gone')], drivers).map((u) => u.id), ['b', 'c']);
});

test('the listed total (per driver plus other) is every upload: what the count and Approve all use', () => {
  const all = [up('a', 'd1'), up('b', null), up('c', 'gone'), up('d', 'd2')];
  const perDriver = drivers.flatMap((d) => all.filter((u) => u.driver_id === d.driver_id));
  assert.equal(perDriver.length + otherUploads(all, drivers).length, all.length);
});
