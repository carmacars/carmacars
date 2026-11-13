import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { parseSort, sortFields, sortOptions, sortRows, sqlOrder } from './sort.ts';

const rows = [
  { id: 1, full_name: 'Zed', created_at: '2026-01-02T00:00:00Z', last_active_at: '2026-03-01T00:00:00Z' },
  { id: 2, full_name: 'amy', created_at: '2026-05-01T00:00:00Z', last_active_at: null },
  { id: 3, full_name: 'Bob', created_at: '2026-03-01T00:00:00Z', last_active_at: '2026-06-01T00:00:00Z' }
];
const ids = (x: Array<{ id: number }>) => x.map((r) => r.id);

test('parseSort accepts only the four sorts', () => {
  assert.equal(parseSort('newest'), 'newest'); assert.equal(parseSort('az'), 'az');
  assert.equal(parseSort('name'), null); assert.equal(parseSort(''), null); assert.equal(parseSort(undefined), null);
});
test('newest, oldest, recently active, A to Z', () => {
  assert.deepEqual(ids(sortRows(rows, 'newest')), [2, 3, 1]);
  assert.deepEqual(ids(sortRows(rows, 'oldest')), [1, 3, 2]);
  assert.deepEqual(ids(sortRows(rows, 'active')), [3, 2, 1], 'the one with no activity time falls back to its created time');
  assert.deepEqual(ids(sortRows(rows, 'az')), [2, 3, 1], 'case does not matter');
  assert.deepEqual(ids(sortRows(rows, null)), [1, 2, 3], 'no sort keeps the order');
});
test('fields and options follow what rows carry', () => {
  assert.deepEqual(sortFields(rows), { created: 'created_at', active: 'last_active_at', name: 'full_name' });
  assert.deepEqual(sortOptions(sortFields(rows)), ['newest', 'oldest', 'active', 'az']);
  assert.deepEqual(sortOptions(sortFields([{ created_at: '2026-01-01', x: 1 }])), ['newest', 'oldest']);
  assert.deepEqual(sortOptions(sortFields([{ name: 'a' }])), [], 'a list with no dates is left alone');
});
test('rows without the value stay stable at the end', () => {
  const r = [{ id: 1, created_at: null, name: 'a' }, { id: 2, created_at: '2026-01-01', name: 'b' }, { id: 3, created_at: null, name: 'c' }];
  assert.deepEqual(ids(sortRows(r, 'newest')), [2, 1, 3]);
});
test('sqlOrder maps a sort to the column and direction', () => {
  const cols = { created: 'created_at', active: 'last_active_at', name: 'full_name' };
  assert.deepEqual(sqlOrder(undefined, cols), { order: 'created_at', asc: false });
  assert.deepEqual(sqlOrder('oldest', cols), { order: 'created_at', asc: true });
  assert.deepEqual(sqlOrder('active', cols), { order: 'last_active_at', asc: false });
  assert.deepEqual(sqlOrder('az', cols), { order: 'full_name', asc: true });
  assert.deepEqual(sqlOrder('az', { created: 'created_at' }), { order: 'created_at', asc: false });
  assert.deepEqual(sqlOrder('junk', cols), { order: 'created_at', asc: false });
});
