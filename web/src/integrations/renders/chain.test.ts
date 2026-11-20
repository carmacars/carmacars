import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { geminiRender, imageBytes, renderChain, workersAiRestyle, type RenderRequest } from './chain.ts';

const img = (n: number, o: { ref?: boolean; sensitive?: boolean } = {}) => ({ bytes: new Uint8Array(2000).fill(n), contentType: 'image/jpeg', ...o });
const ok = (b: number) => async () => new Uint8Array(4000).fill(b);

describe('the render chain (r48 AN)', () => {
  it('a same-angle restyle on the first try goes to Workers AI first', async () => {
    const seen: string[] = [];
    const out = await renderChain([workersAiRestyle(async (m) => { seen.push(m); return ok(7)(); }), geminiRender(async () => ({ ok: true, bytes: new Uint8Array(9), contentType: 'image/png' }))],
      { images: [img(1, { ref: true })], prompt: 'p', photoId: 'x', sameAngle: true, tries: 0 });
    assert.equal(out.ok && out.provider, 'workers-ai');
    assert.equal(seen.length, 1);
  });
  it('a new view, or a second try, goes to Gemini', async () => {
    const r: RenderRequest = { images: [img(1, { ref: true })], prompt: 'p', photoId: 'x', sameAngle: false };
    const chain = [workersAiRestyle(async () => { throw new Error('not asked'); }), geminiRender(async () => ({ ok: true, bytes: new Uint8Array(9), contentType: 'image/png' }))];
    assert.equal((await renderChain(chain, r)).provider, 'gemini');
    assert.equal((await renderChain(chain, { ...r, sameAngle: true, tries: 1 })).provider, 'gemini');
  });
  it('Workers AI failing passes the request on', async () => {
    const out = await renderChain([workersAiRestyle(async () => new Uint8Array(3)), geminiRender(async () => ({ ok: true, bytes: new Uint8Array(9), contentType: 'image/png' }))],
      { images: [img(1, { ref: true })], prompt: 'p', photoId: 'x', sameAngle: true });
    assert.equal(out.provider, 'gemini');
  });
  it('Gemini never gets a check-in photo, and is not asked with only those', async () => {
    let got = -1;
    const g = geminiRender(async (r) => { got = r.images.length; return { ok: true, bytes: new Uint8Array(9), contentType: 'image/png' }; });
    await renderChain([g], { images: [img(1, { ref: true }), img(2, { ref: true, sensitive: true }), img(3)], prompt: 'p', photoId: 'x' });
    assert.equal(got, 2);
    const none = await renderChain([g], { images: [img(2, { ref: true, sensitive: true }), img(3)], prompt: 'p', photoId: 'x' });
    assert.equal(none.ok, false);
  });
  it('reads the answer as bytes', async () => {
    assert.equal((await imageBytes(new ArrayBuffer(4)))?.length, 4);
    assert.equal((await imageBytes(new Response(new Uint8Array(5)).body))?.length, 5);
    assert.equal(await imageBytes({}), null);
  });
});
