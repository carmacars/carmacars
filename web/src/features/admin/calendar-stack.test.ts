import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { BAR, lane, rowHeight, stack, topOf, type Bar } from './calendar-stack.ts';

// The master calendar's layout (0284): overlapping bars on one car are stacked, never drawn over each other.
const bar = (id: string, from: string, to: string, o: Partial<Bar> = {}): Bar => ({ type: 'booking', id, status: 'requested', blocks: true,
  starts_at: `2026-11-${from}T10:00:00Z`, ends_at: `2026-11-${to}T10:00:00Z`, ...o });
const END = Date.parse('2026-12-01T00:00:00Z');

describe('calendar stack', () => {
  it('a booked car on the top lane; requests, offers and placeholders on the lower one', () => {
    assert.equal(lane(bar('a', '04', '07', { status: 'confirmed' })), 'top');
    assert.equal(lane(bar('b', '04', '07', { status: 'confirmed', blocks: false })), 'low');
    assert.equal(lane(bar('c', '04', '07', { status: 'confirmed', placeholder: true })), 'low');
    assert.equal(lane(bar('d', '04', '07', { type: 'block', status: null })), 'top');
    assert.equal(lane(bar('e', '04', '07')), 'low');
  });
  it('two requests for the same days and a placeholder: three rows, nothing on top of anything', () => {
    const list = [bar('r1', '05', '08'), bar('r2', '06', '09'), bar('p', '03', '12', { status: 'confirmed', placeholder: true }), bar('b', '04', '07', { status: 'confirmed' })];
    const st = stack(list, END);
    assert.deepEqual([st.top, st.low], [1, 3]);
    const tops = list.map((e) => topOf(e, st));
    assert.equal(new Set(tops).size, 4);
    assert.equal(topOf(list[3]!, st), 4);
    assert.ok(rowHeight(st) >= 4 + BAR * 4);
  });
  it('bars one after the other share a row; a car with nothing overlapping keeps its usual height', () => {
    const list = [bar('a', '01', '03', { status: 'confirmed' }), bar('b', '03', '05', { status: 'confirmed' }), bar('c', '10', '12')];
    const st = stack(list, END);
    assert.deepEqual([st.top, st.low, st.at.get('bookinga'), st.at.get('bookingb')], [1, 1, 0, 0]);
    assert.equal(rowHeight(st), 52);
  });
  it('an open-ended block runs to the end of the view', () => {
    const st = stack([bar('k', '02', '02', { type: 'block', status: null, ends_at: null }), bar('x', '20', '22', { type: 'block', status: null })], END);
    assert.equal(st.top, 2);
  });
});
