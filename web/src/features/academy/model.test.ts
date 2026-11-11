import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pct, pickVoice, progress, sceneMs, waitLeft, words } from './model.ts';

const scene = (say: string) => ({ caption: 'Cap', say, visual: { kind: 'title' as const, heading: 'h' } });
test('an English voice: the default first, then en-CA, en-US, en-GB; none without English', () => {
  assert.equal(pickVoice([{ lang: 'fr-CA' }, { lang: 'en-GB' }, { lang: 'en-US' }])?.lang, 'en-US');
  assert.equal(pickVoice([{ lang: 'en-GB' }, { lang: 'en-CA' }])?.lang, 'en-CA');
  assert.equal(pickVoice([{ lang: 'en-AU' }, { lang: 'en-GB', default: true }])?.lang, 'en-GB');
  assert.equal(pickVoice([{ lang: 'en_IN' }])?.lang, 'en_IN');
  assert.equal(pickVoice([{ lang: 'fr-FR' }, { lang: 'de-DE' }]), null);
  assert.equal(pickVoice([]), null);
});
test('captions only: the reading time, 3 to 20 seconds, faster at a higher speed', () => {
  assert.equal(sceneMs(scene('one two')), 3000);
  assert.equal(sceneMs(scene(Array(200).fill('w').join(' '))), 20000);
  assert.ok(sceneMs(scene(Array(26).fill('w').join(' ')), 2) < sceneMs(scene(Array(26).fill('w').join(' '))));
  assert.equal(words({ caption: 'Only the caption', visual: { kind: 'title', heading: 'h' } }), 'Only the caption');
});
test('progress and percentages', () => {
  assert.equal(progress(0, 0, 4), 0);
  assert.equal(progress(1, 0.5, 4), 0.375);
  assert.equal(progress(3, 1, 4), 1);
  assert.equal(pct(8000), '80%');
  assert.equal(pct(6666), '66%');
  assert.equal(pct(null), '');
});

test('1154: the time left before the quiz opens', () => {
  const now = Date.parse('2026-11-11T12:00:00Z');
  assert.equal(waitLeft('2026-11-11T12:04:05Z', now), '4:05');
  assert.equal(waitLeft('2026-11-11T13:00:01Z', now), '1:00:01');
  assert.equal(waitLeft('2026-11-11T11:59:00Z', now), '');
  assert.equal(waitLeft(undefined, now), '');
});
