// r50 (3870): connector files become signed links; a marker naming another bucket or a path out of it is refused.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FILE_TTL_SECONDS, fileRef, hasFiles, swapFiles } from './files.ts';
import { TOOLS } from './tools.ts';
import { readFileSync } from 'node:fs';

const sign = async (f: { bucket: string; key: string }) => `https://x.test/f?${f.bucket}:${f.key}`;

test('every _file in an answer is swapped for a ten-minute link, nested or in lists', async () => {
  const out = await swapFiles({ a: 1, recording: { _file: { bucket: 'documents', key: 'calls/twilio/x.mp3', name: 'call 1.mp3' } },
    items: [{ id: 'p', image: { _file: { bucket: 'condition-photos', key: 'bookings/b/1.jpg' } } }] }, sign) as { a: number; recording: unknown; items: Array<{ image: { url: string } }> };
  assert.equal(out.a, 1);
  assert.deepEqual(out.recording, { url: 'https://x.test/f?documents:calls/twilio/x.mp3', name: 'call-1.mp3', expires_in_seconds: FILE_TTL_SECONDS });
  assert.equal(out.items[0]!.image.url, 'https://x.test/f?condition-photos:bookings/b/1.jpg');
  assert.equal(FILE_TTL_SECONDS, 600);
});

test('a marker outside the known buckets or with a path out of its bucket is not signed', async () => {
  assert.equal(fileRef({ _file: { bucket: 'secrets', key: 'a' } }), null);
  assert.equal(fileRef({ _file: { bucket: 'documents', key: '../identity/a' } }), null);
  assert.equal(fileRef({ _file: { bucket: 'documents', key: '/a' } }), null);
  assert.deepEqual(await swapFiles({ f: { _file: { bucket: 'vehicle-public', key: 'a' } } }, sign), { f: null });
  assert.ok(hasFiles({ x: [{ _file: {} }] }) && !hasFiles({ x: 1 }));
});

test('the evidence reads are Admin reads, read only', () => {
  for (const n of ['list_comms', 'get_call_recording', 'get_id_check', 'get_booking_invoice', 'list_chats']) {
    const t = TOOLS.find((x) => x.name === n);
    assert.ok(t && t.readOnly && t.scope === 'admin:read', n);
  }
  const lc = TOOLS.find((x) => x.name === 'list_comms')!.inputSchema as { properties: Record<string, unknown> };
  for (const p of ['booking', 'renter', 'from', 'to', 'kinds', 'cursor']) assert.ok(p in lc.properties, p);
  const ch = TOOLS.find((x) => x.name === 'list_chats')!.inputSchema as { properties: Record<string, unknown> };
  assert.ok('conversation' in ch.properties && 'renter' in ch.properties);
});

test('the migration keeps the reads read only and audits recordings and ID images', () => {
  const sql = readFileSync(new URL('../../../../supabase/migrations/3870_r50_connector_evidence.sql', import.meta.url), 'utf8');
  assert.match(sql, /api_key_check\(p_hash, 'admin:read'/);
  assert.match(sql, /'call_recording_access'/);
  assert.match(sql, /'id_images_access'/);
  assert.doesNotMatch(sql, /\b(insert into|update|delete from) (phone_activity|outbound_calls|messages|chat_messages|bookings|documents)\b/);
  for (const m of sql.matchAll(/set search_path = ([^$]+?) as \$\$/g)) assert.match(m[1]!, /pg_temp$/);
});
