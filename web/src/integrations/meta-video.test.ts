import { test } from 'node:test';
import assert from 'node:assert/strict';
import { publishFacebookVideo, publishInstagramReel, type MetaConfig } from './meta.ts';

const cfg: MetaConfig = { pageId: '1234567', igUserId: '7654321', token: 'tok', version: 'v21.0' };
const fake = (answers: Array<Record<string, unknown>>, seen: string[]) => (async (url: string | URL | Request, init?: RequestInit) => {
  seen.push(`${init?.method ?? 'GET'} ${String(url).split('?')[0]} ${init?.body ? String(init.body) : ''}`);
  return new Response(JSON.stringify(answers.shift() ?? {}), { status: 200 });
}) as typeof fetch;

test('r36b (2220): a Facebook Page video is posted from its public address', async () => {
  const seen: string[] = [];
  const r = await publishFacebookVideo(cfg, { description: 'New car', videoUrl: 'https://photos.example.test/v.mp4' }, fake([{ id: '99' }], seen));
  assert.equal(r.url, 'https://www.facebook.com/1234567/videos/99');
  assert.match(seen[0]!, /POST https:\/\/graph\.facebook\.com\/v21\.0\/1234567\/videos .*file_url=https%3A%2F%2Fphotos\.example\.test%2Fv\.mp4/);
});

test('r36b (2220): an Instagram reel waits until Meta has processed the video, then publishes', async () => {
  const seen: string[] = [];
  const r = await publishInstagramReel(cfg, { caption: 'Reel', videoUrl: 'https://photos.example.test/v.mp4' },
    fake([{ id: 'c1' }, { status_code: 'IN_PROGRESS' }, { status_code: 'FINISHED' }, { id: 'm1' }, { permalink: 'https://www.instagram.com/reel/abc/' }], seen), { sleep: async () => undefined });
  assert.deepEqual(r, { postId: 'm1', url: 'https://www.instagram.com/reel/abc/' });
  assert.match(seen[0]!, /media_type=REELS/);
  assert.match(seen[3]!, /media_publish .*creation_id=c1/);
  await assert.rejects(publishInstagramReel(cfg, { caption: 'Reel', videoUrl: 'https://x.example.test/v.mp4' }, fake([{ id: 'c2' }, { status_code: 'ERROR' }], []), { sleep: async () => undefined }), /could not be processed/);
  await assert.rejects(publishInstagramReel(cfg, { caption: 'Reel', videoUrl: 'https://x.example.test/v.mp4' }, fake([{ id: 'c3' }, { status_code: 'IN_PROGRESS' }], []), { waitMs: 0, sleep: async () => undefined }), /still being processed/);
});
