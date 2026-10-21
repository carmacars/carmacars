import { test } from 'node:test';
import assert from 'node:assert/strict';
import { contentKey, contentText, parseTarget, RENDERER, targetId } from './content.ts';

// The content key of an unsigned document (migration 0077): the same text, title, footer and date give the same key
// (so the sign page finds the open request without rendering); any change gives another.
const blocks = [{ t: 'title', text: 'Vehicle Enrollment Agreement' }, { t: 'p', text: 'Fictional Owner Ltd. enrolls a 2020 Example Sedan.' }] as never;
const x = { title: 'Vehicle Enrollment Agreement, Fictional Owner Ltd.', createdAt: new Date('2026-01-01T00:00:00Z'), footer: 'CarmaCars EA-0001 for Fictional Owner Ltd.' };

test('content key: deterministic, a SHA-256 in hex', async () => {
  const a = await contentKey(blocks, x);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(a, await contentKey(JSON.parse(JSON.stringify(blocks)), { ...x, createdAt: new Date(x.createdAt) }));
});

test('content key: any change to what the PDF is made from changes it', async () => {
  const a = await contentKey(blocks, x);
  const changed = [
    await contentKey([...(blocks as unknown as unknown[]), { t: 'p', text: 'One more line.' }] as never, x),
    await contentKey(blocks, { ...x, title: x.title + ' ' }),
    await contentKey(blocks, { ...x, footer: 'CarmaCars EA-0002 for Fictional Owner Ltd.' }),
    await contentKey(blocks, { ...x, createdAt: new Date('2026-01-02T00:00:00Z') })
  ];
  for (const c of changed) assert.notEqual(c, a);
  assert.equal(new Set(changed).size, changed.length);
});

test('content key: carries the renderer version', () => {
  assert.ok(contentText(blocks, x).includes(RENDERER));
});

test('prepare targets: only known documents, never anything else from the browser', () => {
  assert.deepEqual(parseTarget({ t: 'packet', key: 'enrollment' }), { t: 'packet', key: 'enrollment' });
  assert.deepEqual(parseTarget({ t: 'form', code: 'B' }), { t: 'form', code: 'B' });
  assert.deepEqual(parseTarget({ t: 'partner', extra: 'ignored' }), { t: 'partner' });
  assert.deepEqual(parseTarget({ t: 'form_c', vehicle: '8f32cc8f-0000-4c4d-aeac-000000000001' }), { t: 'form_c', vehicle: '8f32cc8f-0000-4c4d-aeac-000000000001' });
  for (const bad of [null, {}, { t: 'packet', key: 'other' }, { t: 'form', code: 'C' }, { t: 'form_c', vehicle: '../x' }, { t: 'staff' }]) assert.equal(parseTarget(bad), null);
  assert.equal(targetId({ t: 'packet', key: 'title_holding' }), 'packet-title_holding');
});
