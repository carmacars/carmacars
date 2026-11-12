import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createSocket, joinMessage, OFF_KEY, OFF_MS, readFrame, realtimeOff, socketUrl } from './socket.ts';
import type { Timers } from './hub.ts';

// Live updates (release 41): the Realtime websocket, spoken directly (Phoenix protocol), with a fake socket.
const T = 'cccccccccccccccccccccccccccccccc';

describe('live socket messages', () => {
  it('builds the websocket address behind the API address', () => {
    assert.equal(socketUrl('https://api.example.ca', 'k e y'), 'wss://api.example.ca/realtime/v1/websocket?apikey=k%20e%20y&vsn=1.0.0');
    assert.equal(socketUrl('http://127.0.0.1:54321/', 'k'), 'ws://127.0.0.1:54321/realtime/v1/websocket?apikey=k&vsn=1.0.0');
    assert.equal(socketUrl('', 'k'), null);
    assert.equal(socketUrl('not a url', 'k'), null);
  });

  it('joins a public broadcast channel of the topic', () => {
    const m = joinMessage(T, '7');
    assert.equal(m.topic, `realtime:${T}`);
    assert.equal(m.event, 'phx_join');
    assert.equal((m.payload.config as { private: boolean }).private, false);
  });

  it('reads broadcasts and join answers, and nothing else', () => {
    assert.deepEqual(readFrame(JSON.stringify({ topic: `realtime:${T}`, event: 'broadcast', payload: { event: 'bump', payload: {} }, ref: null })), { kind: 'bump', topic: T });
    assert.deepEqual(readFrame(JSON.stringify({ topic: `realtime:${T}`, event: 'phx_reply', payload: { status: 'ok' }, ref: '3', join_ref: '3' })), { kind: 'joined', topic: T, ok: true });
    assert.deepEqual(readFrame(JSON.stringify({ topic: `realtime:${T}`, event: 'phx_reply', payload: { status: 'error' }, ref: '3', join_ref: '3' })), { kind: 'joined', topic: T, ok: false });
    assert.equal(readFrame(JSON.stringify({ topic: 'phoenix', event: 'phx_reply', payload: { status: 'ok' }, ref: '9' })), null);
    assert.equal(readFrame('not json'), null);
    assert.equal(readFrame(42), null);
  });

  it('remembers giving up for ten minutes', () => {
    const store = { v: null as string | null, getItem: (k: string) => (k === OFF_KEY ? store.v : null) };
    assert.equal(realtimeOff(store, 1000), false);
    store.v = '1000';
    assert.equal(realtimeOff(store, 1000 + OFF_MS - 1), true);
    assert.equal(realtimeOff(store, 1000 + OFF_MS), false);
    assert.equal(realtimeOff(null, 1), false);
  });
});

describe('live socket', () => {
  const timers = (): Timers & { run(): void } => {
    const q: (() => void)[] = [];
    return { set: (f) => { q.push(f); return q.length; }, clear: () => {}, run: () => { const f = q.shift(); f?.(); } };
  };
  type Fake = { readyState: number; sent: string[]; send(d: string): void; close(): void; onopen: (() => void) | null; onclose: (() => void) | null; onerror: (() => void) | null; onmessage: ((e: { data: unknown }) => void) | null };
  const fake = (): Fake => ({ readyState: 0, sent: [], send(d) { this.sent.push(d); }, close() { this.readyState = 3; }, onopen: null, onclose: null, onerror: null, onmessage: null });

  it('joins, says joined on the answer and passes broadcasts on', () => {
    const made: Fake[] = [];
    const bumps: string[] = [];
    const states: boolean[] = [];
    const s = createSocket({ url: 'wss://x', ws: () => { const f = fake(); made.push(f); return f; }, onBump: (t) => bumps.push(t), onJoined: (j) => states.push(j), timers: timers() });
    s.set([T]);
    const ws = made[0]!;
    ws.readyState = 1; ws.onopen!();
    const join = JSON.parse(ws.sent[0]!) as { ref: string };
    ws.onmessage!({ data: JSON.stringify({ topic: `realtime:${T}`, event: 'phx_reply', payload: { status: 'ok' }, ref: join.ref, join_ref: join.ref }) });
    assert.deepEqual(states, [true]);
    ws.onmessage!({ data: JSON.stringify({ topic: `realtime:${T}`, event: 'broadcast', payload: {}, ref: null }) });
    ws.onmessage!({ data: JSON.stringify({ topic: 'realtime:someoneelse000', event: 'broadcast', payload: {}, ref: null }) });
    assert.deepEqual(bumps, [T], 'only the joined topic');
    ws.readyState = 3; ws.onclose!();
    assert.deepEqual(states, [true, false], 'a dropped connection is not joined');
    s.close();
  });

  it('gives up when the server has no Realtime (two failures that never opened)', () => {
    let gaveUp = false;
    let made = 0;
    const t = timers();
    createSocket({ url: 'wss://x', ws: () => { made++; const f = fake(); queueMicrotask(() => f.onclose?.()); return f; }, onBump: () => {}, onJoined: () => {}, timers: t, giveUp: () => { gaveUp = true; } });
    return new Promise<void>((done) => queueMicrotask(() => {
      t.run(); // the retry
      queueMicrotask(() => { assert.equal(made, 2); assert.equal(gaveUp, true); done(); });
    }));
  });
});
