// The renter's accident report (release 35, 0912): the file kinds, what is required, and the payload.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { draftPayload, draftProblem, emptyDraft, mediaKind } from './report.ts';

test('photos and videos are known from their first bytes', () => {
  assert.equal(mediaKind(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))?.ext, 'jpg');
  assert.equal(mediaKind(new Uint8Array([0x89, 0x50, 0x4e, 0x47]))?.ext, 'png');
  assert.equal(mediaKind(new Uint8Array([0x1a, 0x45, 0xdf, 0xa3]))?.ext, 'webm');
  const ftyp = (brand: string) => new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, ...[...brand].map((c) => c.charCodeAt(0))]);
  assert.equal(mediaKind(ftyp('qt  '))?.ext, 'mov');
  assert.equal(mediaKind(ftyp('isom'))?.video, true);
  assert.equal(mediaKind(new Uint8Array([0x25, 0x50, 0x44, 0x46])), null);
});

test('what happened, anyone hurt and can it be driven are required; the rest is optional', () => {
  const d = emptyDraft();
  assert.match(draftProblem(d)!, /what happened/);
  d.description = 'Rear-ended at a light';
  assert.match(draftProblem(d)!, /hurt/);
  d.anyone_hurt = 'no';
  assert.match(draftProblem(d)!, /driven/);
  d.drivable = 'yes';
  assert.equal(draftProblem(d), null);
  d.occurred_at = '2999-01-01T10:00';
  assert.match(draftProblem(d)!, /future/);
});

test('the payload: the other party only when given, answers as booleans', () => {
  const d = { ...emptyDraft(), description: 'Scrape', anyone_hurt: 'no' as const, drivable: 'yes' as const };
  const p = draftPayload('b1', d);
  assert.equal(p.other_party, null);
  assert.equal(p.anyone_hurt, false);
  assert.equal(p.drivable, true);
  const q = draftPayload('b1', { ...d, other_plate: 'ABCD 123' });
  assert.deepEqual(q.other_party, { name: '', phone: '', plate: 'ABCD 123', coverage: '' });
});
