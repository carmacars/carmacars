import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { BACKOFF_MAX_MS, COALESCE_MS, createLiveHub, nextDelay, POLL_MS, SAFETY_MS, validTopic, type SocketFactory, type Timers } from './hub.ts';

// Live updates (release 41, migration 2500): the hub behind useLive, on a fake clock.
function clock() {
  let now = 0, seq = 0;
  const due = new Map<number, { at: number; f: () => void }>();
  const timers: Timers = { set: (f, ms) => { const id = ++seq; due.set(id, { at: now + ms, f }); return id; }, clear: (t) => { due.delete(t as number); } };
  const advance = async (ms: number) => {
    const end = now + ms;
    for (;;) {
      const next = [...due.entries()].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) break;
      due.delete(next[0]); now = next[1].at; next[1].f();
      await new Promise((r) => setImmediate(r));
    }
    now = end;
    await new Promise((r) => setImmediate(r));
  };
  return { timers, advance, pending: () => due.size };
}

const A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

function setup(o: { socket?: SocketFactory; fail?: () => boolean } = {}) {
  const c = clock();
  const versions: Record<string, string | null> = { [A]: '1:1', [B]: null };
  let visible = true;
  const polls: string[][] = [];
  const hub = createLiveHub({
    timers: c.timers,
    visible: () => visible,
    poll: async (t) => { polls.push(t); if (o.fail?.()) throw new Error('down'); return Object.fromEntries(t.map((x) => [x, versions[x] ?? null])); },
    socket: o.socket
  });
  return { hub, c, versions, polls, setVisible: (v: boolean) => { visible = v; hub.visibility(); } };
}

describe('live hub', () => {
  it('reads at once, then every 2 s, and tells a change once', async () => {
    const s = setup();
    let n = 0;
    s.hub.subscribe([A], () => n++);
    await s.c.advance(0);
    assert.equal(s.polls.length, 1, 'the first read is the start');
    assert.equal(n, 0);
    await s.c.advance(POLL_MS);
    assert.equal(s.polls.length, 2);
    assert.equal(n, 0, 'no change, nothing told');
    s.versions[A] = '2:2';
    await s.c.advance(POLL_MS + COALESCE_MS);
    assert.equal(n, 1, 'the change is told within about 2 seconds');
    await s.c.advance(POLL_MS * 3);
    assert.equal(n, 1, 'and only once');
  });

  it('tells a first change on a topic that had none', async () => {
    const s = setup();
    let n = 0;
    s.hub.subscribe([B], () => n++);
    await s.c.advance(0);
    s.versions[B] = '5:1';
    await s.c.advance(POLL_MS + COALESCE_MS);
    assert.equal(n, 1);
  });

  it('coalesces changes on several topics of one screen', async () => {
    const s = setup();
    let n = 0;
    s.hub.subscribe([A, B], () => n++);
    await s.c.advance(0);
    s.versions[A] = '9:9'; s.versions[B] = '3:3';
    await s.c.advance(POLL_MS + COALESCE_MS);
    assert.equal(n, 1);
    assert.deepEqual(s.polls[0], [A, B], 'one read for every topic');
  });

  it('reads nothing while hidden and catches up at once when shown', async () => {
    const s = setup();
    let n = 0;
    s.hub.subscribe([A], () => n++);
    await s.c.advance(0);
    s.setVisible(false);
    const before = s.polls.length;
    await s.c.advance(60_000);
    assert.equal(s.polls.length, before, 'no reads while hidden');
    assert.equal(s.c.pending(), 0);
    s.versions[A] = '7:7';
    s.setVisible(true);
    await s.c.advance(COALESCE_MS);
    assert.equal(s.polls.length, before + 1);
    assert.equal(n, 1, 'the change made while hidden is told on show');
  });

  it('backs off after failures and recovers', async () => {
    let down = true;
    const s = setup({ fail: () => down });
    s.hub.subscribe([A], () => {});
    await s.c.advance(0);
    await s.c.advance(nextDelay(false, 1));
    assert.equal(s.polls.length, 2);
    assert.ok(nextDelay(false, 1) > POLL_MS && nextDelay(false, 9) === BACKOFF_MAX_MS);
    down = false;
    await s.c.advance(nextDelay(false, 2));
    assert.equal(s.polls.length, 3);
    await s.c.advance(POLL_MS);
    assert.equal(s.polls.length, 4, 'back to every 2 seconds');
  });

  it('with Realtime joined: a broadcast is told at once and the reads slow to the safety net', async () => {
    let bump: (t: string) => void = () => {};
    let joined: (j: boolean) => void = () => {};
    const sets: string[][] = [];
    const s = setup({ socket: (b, j) => { bump = b; joined = j; return { set: (t) => sets.push(t), close: () => {} }; } });
    let n = 0;
    s.hub.subscribe([A], () => n++);
    assert.deepEqual(sets.at(-1), [A], 'the socket joins the topic');
    await s.c.advance(0);
    joined(true);
    assert.equal(s.hub.mode(), 'realtime');
    const before = s.polls.length;
    await s.c.advance(SAFETY_MS - 1);
    assert.equal(s.polls.length, before, 'no 2-second reads while joined');
    bump(A);
    await s.c.advance(COALESCE_MS);
    assert.equal(n, 1);
    // the safety read sees the new version as its start: the same change is not told twice
    s.versions[A] = '2:2';
    await s.c.advance(SAFETY_MS);
    assert.equal(n, 1);
    joined(false);
    assert.equal(s.hub.mode(), 'polling');
  });

  it('unsubscribes: no more reads, and other screens keep theirs', async () => {
    const s = setup();
    let a = 0, b = 0;
    const offA = s.hub.subscribe([A], () => a++);
    s.hub.subscribe([B], () => b++);
    await s.c.advance(0);
    offA();
    s.versions[A] = '8:8'; s.versions[B] = '1:1';
    await s.c.advance(POLL_MS + COALESCE_MS);
    assert.equal(a, 0);
    assert.equal(b, 1);
    assert.deepEqual(s.polls.at(-1), [B]);
  });

  it('accepts only the server tokens', () => {
    assert.ok(validTopic(A));
    for (const bad of ['', 'short', 'UPPERCASE0000000', 'with space 000000', 'a'.repeat(65), null, 5]) assert.ok(!validTopic(bad));
    const s = setup();
    s.hub.subscribe(['bad topic'], () => {});
    assert.equal(s.hub.mode(), 'idle');
  });
});
