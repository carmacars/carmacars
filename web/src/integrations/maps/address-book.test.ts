import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addressBook, type AddressDb } from './address-book.ts';
import type { MapsAdapter } from './types.ts';

const calls: string[] = [];
const inner: MapsAdapter = {
  name: 'google',
  async autocomplete(q) { calls.push(`google:${q}`); return [{ id: 'ChIJ1', label: 'Google place' }]; },
  async suggest(q) { calls.push(`google:${q}`); return { items: [{ id: 'ChIJ1', label: 'Google place' }], limited: false }; },
  async place(id) { calls.push(`details:${id}`); return { id, label: 'Google place', lat: 43.6, lng: -79.4 }; },
  async distanceKm() { calls.push('routes'); return 12; }
};
const rows = [{ id: 'ca-7', label: '65 Front St W, Toronto, ON M5J 1E6' }];
const db: AddressDb = {
  async search(q) { return /^65 fr/i.test(q) ? rows : []; },
  async get(id) { return id === 'ca-7' ? { id, label: rows[0]!.label, lat: 43.64, lng: -79.38, parts: { street: '65 Front St W', unit: '', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' } } : null; }
};

test('the database answers first; Google is not asked', async () => {
  calls.length = 0;
  const m = addressBook(inner, db);
  assert.deepEqual((await m.suggest!('65 fro', 's')).items, rows);
  assert.deepEqual(await m.autocomplete('65 fro', 's'), rows);
  assert.deepEqual(calls, []);
});

test('nothing in the database (no number, not found): the adapter behind answers', async () => {
  calls.length = 0;
  const m = addressBook(inner, db);
  assert.equal((await m.suggest!('cn tower', 's')).items[0]!.id, 'ChIJ1');
  assert.equal((await m.suggest!('12 nowhere', 's')).items[0]!.id, 'ChIJ1');
  assert.deepEqual(calls, ['google:cn tower', 'google:12 nowhere']);
});

test('a database address in its parts, never sent to Place Details; a Google id still is', async () => {
  calls.length = 0;
  const m = addressBook(inner, db);
  const p = await m.place('ca-7', 's');
  assert.equal(p?.parts?.postal_code, 'M5J 1E6');
  assert.equal(p?.lat, 43.64);
  await m.place('ChIJ1', 's');
  assert.deepEqual(calls, ['details:ChIJ1']);
});

test('a database that cannot be read: the adapter behind answers; a point missing: no distance', async () => {
  const broken: AddressDb = { search: async () => { throw new Error('down'); }, get: async () => ({ id: 'ca-1', label: 'x', lat: null, lng: null, parts: { street: 'x', unit: '', city: '', province: 'ON', postal_code: '', country: 'Canada' } }) };
  const m = addressBook(inner, broken);
  assert.equal((await m.suggest!('65 front', 's')).items[0]!.id, 'ChIJ1');
  const p = await m.place('ca-1', 's');
  assert.equal(await m.distanceKm({ lat: 43, lng: -79 }, { lat: p!.lat, lng: p!.lng }), null);
});
