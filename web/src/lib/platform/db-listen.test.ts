// Release 48 (src/lib/platform/db-listen.ts): the server's listen for queued texts, emails and pushes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createKicker, createListener, listenUrl, readPayload, retryDelay, type ListenConn, type Timers } from './db-listen.ts';

function fakeTimers() {
  let now = 0;
  let id = 0;
  const q = new Map<number, { at: number; f: () => void }>();
  const t: Timers & { advance(ms: number): Promise<void>; pending(): number; now(): number } = {
    now: () => now,
    set: (f, ms) => { q.set(++id, { at: now + ms, f }); return id; },
    clear: (k) => { q.delete(k as number); },
    pending: () => q.size,
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        const next = [...q.entries()].filter(([, v]) => v.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        q.delete(next[0]); now = next[1].at; next[1].f();
        for (let i = 0; i < 5; i++) await Promise.resolve();
      }
      now = end;
      for (let i = 0; i < 5; i++) await Promise.resolve();
    }
  };
  return t;
}

test('the payload is the table and the row only', () => {
  assert.deepEqual(readPayload('phone_outbox:6f1c2a34-0000-4000-8000-000000000001'), { table: 'phone_outbox', id: '6f1c2a34-0000-4000-8000-000000000001' });
  for (const bad of ['', 'x', 'Phone:1', 'a:b c', null, 3, 'notification_outbox:' + 'f'.repeat(65)]) assert.equal(readPayload(bad), null, String(bad));
});

test('a burst of notifies runs the kick once; a notify during a kick runs it once more', async () => {
  const t = fakeTimers();
  let release: (() => void) | null = null;
  let runs = 0;
  const k = createKicker(() => { runs++; return new Promise<void>((r) => { release = r; }); }, { timers: t, now: t.now });
  for (let i = 0; i < 20; i++) k.poke();
  await t.advance(249);
  assert.equal(runs, 0, 'debounced');
  await t.advance(1);
  assert.equal(runs, 1);
  k.poke(); k.poke();
  assert.equal(runs, 1, 'single flight');
  await t.advance(400);
  release!();
  await t.advance(0);
  await t.advance(599);
  assert.equal(runs, 1, 'at most one start a second');
  await t.advance(1);
  assert.equal(runs, 2, 'one trailing run');
  release!();
  await t.advance(1000);
  assert.equal(runs, 2);
  assert.equal(k.busy(), false);
});

test('a failed kick never stops the next one', async () => {
  const t = fakeTimers();
  let runs = 0;
  const k = createKicker(async () => { runs++; throw new Error('db down'); }, { timers: t, now: t.now });
  k.poke(); await t.advance(250);
  k.poke(); await t.advance(1000);
  assert.equal(runs, 2);
});

test('the listener kicks on connect and on every notify, and reconnects with a longer wait each time', async () => {
  const t = fakeTimers();
  let kicks = 0;
  let tries = 0;
  let h: { onNotify: (p: string) => void; onClose: () => void } | null = null;
  let up = false;
  const conn: ListenConn = { ping: async () => { if (!up) throw new Error('gone'); }, close: async () => undefined };
  const l = createListener({ timers: t, kick: () => { kicks++; }, pingMs: 60_000,
    connect: async (x) => { tries++; if (!up) throw new Error('refused'); h = x; return conn; } });
  await t.advance(0);
  assert.equal(tries, 1); assert.equal(l.connected(), false); assert.equal(kicks, 0);
  await t.advance(999); assert.equal(tries, 1);
  await t.advance(1); assert.equal(tries, 2, 'again after 1 s');
  await t.advance(2000); assert.equal(tries, 3, 'then 2 s');
  up = true;
  await t.advance(5000);
  assert.equal(tries, 4); assert.equal(l.connected(), true);
  assert.equal(kicks, 1, 'one kick for what was queued while down');
  h!.onNotify('phone_outbox:1a2b');
  h!.onNotify('not a payload');
  assert.equal(kicks, 2);
  assert.equal(l.notifies(), 2);
  // the connection drops: back after 1 s (the failures start over once connected)
  h!.onClose();
  assert.equal(l.connected(), false);
  await t.advance(1000);
  assert.equal(tries, 5); assert.equal(l.connected(), true); assert.equal(kicks, 3);
  // a dead connection found by the ping
  up = false;
  await t.advance(60_000);
  assert.equal(l.connected(), false);
  await l.stop();
  await t.advance(120_000);
  assert.equal(tries, 5, 'stopped: no more tries');
});

test('a late close of an old connection is ignored', async () => {
  const t = fakeTimers();
  const hs: Array<{ onNotify: (p: string) => void; onClose: () => void }> = [];
  let kicks = 0;
  const l = createListener({ timers: t, kick: () => { kicks++; }, connect: async (x) => { hs.push(x); return { ping: async () => undefined, close: async () => undefined }; } });
  await t.advance(0);
  hs[0]!.onClose();
  await t.advance(1000);
  assert.equal(hs.length, 2);
  hs[0]!.onClose();
  hs[0]!.onNotify('phone_outbox:1');
  assert.equal(l.connected(), true);
  assert.equal(kicks, 2, 'the old connection kicks nothing');
  await l.stop();
});

test('retry waits and the address', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 9].map(retryDelay), [1000, 2000, 5000, 10_000, 30_000, 30_000]);
  assert.equal(listenUrl({}), null);
  assert.equal(listenUrl({ DATABASE_LISTEN_URL: 'https://x' }), null);
  assert.equal(listenUrl({ DATABASE_LISTEN_URL: 'postgresql://listen@db:5432/postgres', DB_LISTEN: '0' }), null);
  assert.equal(listenUrl({ DATABASE_LISTEN_URL: ' postgresql://listen@db:5432/postgres ' }), 'postgresql://listen@db:5432/postgres');
});
