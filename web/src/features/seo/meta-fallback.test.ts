// r47: metadata that cannot be read never fails the page (React #441).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isNextSignal, metaOr, titleFromPath } from './meta-fallback.ts';

test('metaOr: a failed read gives the fallback, a good one its own', async () => {
  assert.deepEqual(await metaOr(async () => ({ title: 'A' }), { title: 'B' }), { title: 'A' });
  assert.deepEqual(await metaOr(async () => { throw new Error('canceling statement due to statement timeout'); }, { title: 'B' }), { title: 'B' });
});
test('metaOr: notFound and redirect pass through', async () => {
  const nf = Object.assign(new Error('NEXT_HTTP_ERROR_FALLBACK;404'), { digest: 'NEXT_HTTP_ERROR_FALLBACK;404' });
  await assert.rejects(metaOr(async () => { throw nf; }, { title: 'B' }), (e) => e === nf);
  assert.ok(isNextSignal({ digest: 'NEXT_REDIRECT;replace;/x;308;' }));
  assert.ok(!isNextSignal(new Error('x')));
  assert.ok(!isNextSignal(null));
});
test('titleFromPath', () => {
  assert.equal(titleFromPath('/car-rental/limo-service/saipan-mp'), 'Limo service, saipan mp | CarmaCars');
  assert.equal(titleFromPath('/'), 'CarmaCars');
});
