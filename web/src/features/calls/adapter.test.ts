import { test } from 'node:test';
import assert from 'node:assert/strict';
import { acceptSlide, orderPeople, parseMsg, type Person } from './adapter.ts';

test('5010: only well formed messages pass the data channel', () => {
  assert.deepEqual(parseMsg({ t: 'slide', i: 3 }), { t: 'slide', i: 3 });
  assert.equal(parseMsg({ t: 'slide', i: -1 }), null);
  assert.equal(parseMsg({ t: 'slide', i: 1.5 }), null);
  assert.deepEqual(parseMsg({ t: 'chat', id: 'abcd1', text: '  hi  ', at: 1 }), { t: 'chat', id: 'abcd1', text: 'hi', at: 1 });
  assert.equal(parseMsg({ t: 'chat', id: 'abcd1', text: '   ', at: 1 }), null);
  assert.equal((parseMsg({ t: 'chat', id: 'abcd1', text: 'x'.repeat(900), at: 1 }) as { text: string }).text.length, 500);
  assert.deepEqual(parseMsg({ t: 'hand', up: true }), { t: 'hand', up: true });
  assert.equal(parseMsg({ t: 'eval', code: 'x' }), null);
  assert.equal(parseMsg('slide'), null);
});

test('5010: only the presenter moves everyone\'s slide', () => {
  assert.equal(acceptSlide('presenter', { t: 'slide', i: 2 }), true);
  assert.equal(acceptSlide('member', { t: 'slide', i: 2 }), false);
  assert.equal(acceptSlide(undefined, { t: 'slide', i: 2 }), false);
});

test('5010: the tiles: a shared screen first, then the presenter, the others, me last', () => {
  const p = (name: string, o: Partial<Person> = {}): Person => ({ identity: name, name, role: 'member', local: false, mic: true, cam: true, screen: false, speaking: false, ...o });
  assert.deepEqual(orderPeople([p('Me', { local: true }), p('Zed'), p('Abbas', { role: 'presenter' }), p('Ann'), p('Bo', { screen: true })]).map((x) => x.name), ['Bo', 'Abbas', 'Ann', 'Zed', 'Me']);
});
