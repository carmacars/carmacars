import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { beatMs, createHeartbeat, type Timers } from './heartbeat.ts';

// Live visitors heartbeat (migration 0103): the tracker's timer, on a fake clock.
function clock() {
  let now = 0, seq = 0;
  const due = new Map<number, { at: number; f: () => void }>();
  const timers: Timers = { set: (f, ms) => { const id = ++seq; due.set(id, { at: now + ms, f }); return id; }, clear: (t) => { due.delete(t as number); } };
  const advance = (ms: number) => {
    const end = now + ms;
    for (;;) {
      const next = [...due.entries()].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) break;
      due.delete(next[0]); now = next[1].at; next[1].f();
    }
    now = end;
  };
  return { timers, advance, pending: () => due.size };
}

function setup(intervalS = 45) {
  const c = clock();
  let visible = true;
  const beats: number[] = [];
  let t = 0;
  const hb = createHeartbeat({ visible: () => visible, beat: () => beats.push(t), intervalMs: () => beatMs(intervalS), timers: c.timers });
  const advance = (ms: number) => { const steps = Math.ceil(ms / 1000); for (let i = 0; i < steps; i++) { t += 1000; c.advance(1000); } };
  return { hb, beats, advance, setVisible: (v: boolean) => { visible = v; hb.visibility(); }, pending: c.pending };
}

describe('the heartbeat interval', () => {
  it('45 seconds by default, the setting otherwise, kept between 15 seconds and 5 minutes', () => {
    assert.equal(beatMs(undefined), 45_000);
    assert.equal(beatMs('x'), 45_000);
    assert.equal(beatMs(0), 45_000);
    assert.equal(beatMs(30), 30_000);
    assert.equal(beatMs('60'), 60_000);
    assert.equal(beatMs(5), 15_000);
    assert.equal(beatMs(9999), 300_000);
  });
});

describe('the heartbeat timer', () => {
  it('beats every interval while the page is visible', () => {
    const s = setup();
    s.hb.start();
    s.advance(44_000);
    assert.equal(s.beats.length, 0);
    s.advance(1_000);
    assert.deepEqual(s.beats, [45_000]);
    s.advance(10 * 60_000);
    // a visitor reading one page for 10 minutes keeps beating: 14 beats in 10 minutes 45 seconds
    assert.equal(s.beats.length, 14);
  });

  it('stops while the tab is hidden and beats at once when it is shown again', () => {
    const s = setup();
    s.hb.start();
    s.advance(45_000);
    assert.equal(s.beats.length, 1);
    s.setVisible(false);
    assert.equal(s.hb.running(), false);
    s.advance(10 * 60_000);
    assert.equal(s.beats.length, 1, 'no beat while hidden');
    s.setVisible(true);
    assert.equal(s.beats.length, 2, 'a beat when shown');
    s.advance(45_000);
    assert.equal(s.beats.length, 3);
  });

  it('another send restarts the wait, so a busy page sends no extra heartbeat', () => {
    const s = setup();
    s.hb.start();
    s.advance(40_000);
    s.hb.reset();
    s.advance(40_000);
    assert.equal(s.beats.length, 0);
    s.advance(5_000);
    assert.equal(s.beats.length, 1);
  });

  it('stopped (the page closed): no beat and no timer left, even when shown', () => {
    const s = setup();
    s.hb.start();
    s.hb.stop();
    s.setVisible(true);
    s.advance(5 * 60_000);
    assert.equal(s.beats.length, 0);
    assert.equal(s.pending(), 0);
    s.hb.start();
    s.advance(45_000);
    assert.equal(s.beats.length, 1, 'started again (back from the back-forward cache)');
  });

  it('never starts a timer while hidden', () => {
    const s = setup();
    s.setVisible(false);
    s.hb.start();
    assert.equal(s.hb.running(), false);
    s.advance(5 * 60_000);
    assert.equal(s.beats.length, 0);
  });

  it('a new interval (the setting changed) applies from the next wait', () => {
    let every = 45;
    const c = clock();
    const beats: number[] = [];
    let t = 0;
    const hb = createHeartbeat({ visible: () => true, beat: () => beats.push(t), intervalMs: () => beatMs(every), timers: c.timers });
    hb.start();
    const adv = (ms: number) => { for (let i = 0; i < ms / 1000; i++) { t += 1000; c.advance(1000); } };
    adv(30_000);
    every = 20;
    adv(35_000);
    assert.deepEqual(beats, [45_000, 65_000]);
  });

  it('2026-10-30: a visible tab nobody touches stops after 15 minutes; a touch beats at once and starts again', () => {
    const c = clock();
    let t = 0;
    const beats: number[] = [];
    const hb = createHeartbeat({ visible: () => true, beat: () => beats.push(t), intervalMs: () => 60_000, timers: c.timers, now: () => t, idleStopMs: 15 * 60_000 });
    hb.start();
    const adv = (ms: number) => { for (let i = 0; i < ms / 1000; i++) { t += 1000; c.advance(1000); } };
    adv(30 * 60_000);
    assert.equal(beats.length, 14);
    assert.equal(hb.running(), false);
    hb.activity();
    assert.equal(beats.length, 15);
    assert.equal(hb.running(), true);
    adv(60_000);
    assert.equal(beats.length, 16);
  });

  it('activity while beating changes nothing but the idle clock', () => {
    const c = clock();
    let t = 0;
    const beats: number[] = [];
    const hb = createHeartbeat({ visible: () => true, beat: () => beats.push(t), intervalMs: () => 60_000, timers: c.timers, now: () => t, idleStopMs: 15 * 60_000 });
    hb.start();
    for (let m = 0; m < 30; m++) { for (let i = 0; i < 60; i++) { t += 1000; c.advance(1000); } hb.activity(); }
    assert.equal(beats.length, 30);
  });
});
