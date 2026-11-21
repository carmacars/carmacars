// r48 (3263): a published post's results read back from Meta.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postInsights, type MetaConfig } from './meta.ts';

const cfg: MetaConfig = { pageId: '1234567', igUserId: '7654321', token: 'tok', version: 'v21.0' };
const fake = (answers: Array<Record<string, unknown> | number>, seen: string[]) => (async (url: string | URL | Request) => {
  seen.push(String(url));
  const a = answers.shift() ?? {};
  return typeof a === 'number' ? new Response(JSON.stringify({ error: { message: 'no permission' } }), { status: a }) : new Response(JSON.stringify(a), { status: 200 });
}) as typeof fetch;

test('Instagram: reach, likes, comments, shares, saves and views of the media', async () => {
  const seen: string[] = [];
  const r = await postInsights(cfg, { channel: 'instagram', postId: 'm1' }, fake([{ data: [
    { name: 'reach', total_value: { value: 1200 } }, { name: 'likes', values: [{ value: 90 }] }, { name: 'comments', values: [{ value: 4 }] },
    { name: 'shares', values: [{ value: 7 }] }, { name: 'saved', values: [{ value: 12 }] }, { name: 'views', values: [{ value: 3400 }] }, { name: 'other', values: [{ value: 1 }] }] }], seen));
  assert.deepEqual(r, { reach: 1200, likes: 90, comments: 4, shares: 7, saves: 12, views: 3400 });
  assert.match(seen[0]!, /\/v21\.0\/m1\/insights\?metric=reach%2Clikes%2Ccomments%2Cshares%2Csaved%2Cviews/);
});

test('the Facebook Page: reactions, comments and shares; the reach when the token may read insights, left out when not', async () => {
  const seen: string[] = [];
  const r = await postInsights(cfg, { channel: 'facebook_page', postId: '1_2', video: true },
    fake([{ reactions: { summary: { total_count: 40 } }, comments: { summary: { total_count: 3 } }, shares: { count: 5 } },
      { data: [{ name: 'post_impressions_unique', values: [{ value: 800 }] }, { name: 'post_video_views', values: [{ value: 600 }] }] }], seen));
  assert.deepEqual(r, { likes: 40, comments: 3, shares: 5, reach: 800, views: 600 });
  const noInsights = await postInsights(cfg, { channel: 'facebook_page', postId: '1_3' }, fake([{ reactions: { summary: { total_count: 2 } }, comments: { summary: { total_count: 0 } } }, 403], []));
  assert.deepEqual(noInsights, { likes: 2, comments: 0, shares: 0 });
});

test('a post Meta no longer has is an error, never zeros', async () => {
  await assert.rejects(postInsights(cfg, { channel: 'instagram', postId: 'gone' }, fake([404], [])), /Meta: no permission/);
});
