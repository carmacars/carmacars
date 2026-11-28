import { test } from 'node:test';
import assert from 'node:assert/strict';
import { HONEST_NOTE, IntegrityWatch, cdpProbe, markersOf } from './integrity.ts';

// R51 (5300, REQ-130): what the quiz page reports. The database decides the reasons (99_r51_academy_integrity.sql).
const fresh = () => new IntegrityWatch({ webdriver: false, markers: [], cdp: false }, 1000);

test('the disclaimer says it plainly, with no long dash', () => {
  assert.match(HONEST_NOTE, /^Answer yourself\. Using AI tools, browser agents or computer-use software on this test is not allowed and breaks your agreement; CarmaCars may take legal action\.$/);
});

test('a person: moves before each press, trusted events, answers spaced out: nothing to report', () => {
  const w = fresh();
  let t = 1000;
  for (const q of ['a', 'b', 'c']) {
    for (let i = 0; i < 12; i++) w.pointerMove({ pointerType: 'mouse' });
    w.pointerDown({ pointerType: 'mouse', isTrusted: true });
    w.input({ isTrusted: true });
    t += 9000; w.pick(q, t);
  }
  assert.deepEqual(w.report(), { webdriver: false, cdp: false, markers: [], untrusted: 0, jumps: 0, pastes: 0, copies: 0, leaves: 0, gaps_ms: [9000, 9000, 9000] });
});

test('an agent: presses with no movement, scripted clicks, paste, copy, tab switches, instant answers', () => {
  const w = new IntegrityWatch({ webdriver: true, markers: ['__pwInitScripts'], cdp: true }, 1000);
  w.pointerDown({ pointerType: 'mouse', isTrusted: true });
  w.pointerMove({ pointerType: 'mouse' });
  w.pointerDown({ pointerType: 'mouse', isTrusted: true });
  w.input({ isTrusted: false }); w.input({ isTrusted: false });
  w.paste(); w.copy();
  w.leave(); w.leave(); w.back(); w.leave();
  w.pick('a', 1200); w.pick('a', 1300); w.pick('b', 1400);
  const r = w.report();
  assert.equal(r.jumps, 2, 'two presses without three moves first');
  assert.equal(r.untrusted, 2);
  assert.equal(r.pastes + r.copies, 2);
  assert.equal(r.leaves, 2, 'blur and hidden together count once until the page is back');
  assert.deepEqual(r.gaps_ms, [200, 200], 'only the first pick of a question counts');
  assert.equal(r.webdriver && r.cdp, true);
});

test('touch presses are not pointer jumps (a finger does not move a cursor first)', () => {
  const w = fresh();
  w.pointerDown({ pointerType: 'touch', isTrusted: true }); w.pointerDown({ pointerType: 'pen', isTrusted: true });
  assert.equal(w.report().jumps, 0);
});

test('markers: driver globals and document keys are found by name, a clean page has none', () => {
  assert.deepEqual(markersOf({}, {}), []);
  assert.deepEqual(markersOf({ __pwInitScripts: 1, callPhantom: () => 0 }, { $cdc_asdjflasutopfhvcZLmcfl_: 1 }), ['__pwInitScripts', 'callPhantom', '$cdc_asdjflasutopfhvcZLmcfl_']);
  assert.deepEqual(markersOf({}, { documentElement: { getAttribute: (n: string) => (n === 'webdriver' ? 'true' : null) } }), ['webdriver attribute']);
});

test('the devtools protocol probe: true only when the logged error\'s stack is read', () => {
  assert.equal(cdpProbe(() => undefined), false);
  assert.equal(cdpProbe((e) => { void (e as Error).stack; }), true);
});
