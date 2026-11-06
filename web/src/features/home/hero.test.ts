// The hero's fleet slides (release 28, B5): the cross-fade keyframes.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heroKeyframes } from './hero-keyframes.ts';

test('one car: no animation; three cars: 18 seconds, each in for 6', () => {
  assert.equal(heroKeyframes(1), '');
  const k = heroKeyframes(3);
  assert.match(k, /^@keyframes hero-slides-3\{0%\{opacity:0\}5\.556%\{opacity:1\}33\.333%\{opacity:1\}38\.889%\{opacity:0\}100%\{opacity:0\}\}$/);
});
