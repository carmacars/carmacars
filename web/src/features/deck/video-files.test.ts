import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DECK_VIDEO, deckVideoPaths, deckVideoUrls } from './video-files.ts';

const API = 'https://abc.supabase.co/storage/v1';
const rows = deckVideoPaths().map((path) => ({ path, signedURL: `/object/sign/${DECK_VIDEO.bucket}/${path}?token=t`, error: null }));

test('the four files, signed, become absolute links', () => {
  const u = deckVideoUrls(`${API}/`, rows);
  assert.ok(u);
  assert.equal(u.hd, `${API}/object/sign/investor-media/deck-video/carmacars-investor-1080p.mp4?token=t`);
  assert.equal(u.captions, `${API}/object/sign/investor-media/deck-video/captions.vtt?token=t`);
  assert.equal(Object.keys(u).length, 4);
});

test('no video until every file is there', () => {
  assert.equal(deckVideoUrls(API, rows.slice(1)), null);
  assert.equal(deckVideoUrls(API, rows.map((r, i) => (i === 2 ? { ...r, signedURL: null, error: 'Object not found' } : r))), null);
  assert.equal(deckVideoUrls(API, { error: 'Bucket not found' }), null);
});
