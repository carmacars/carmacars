// r47: the translation guard (dom-guard.ts).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DOM_GUARD_SCRIPT } from './dom-guard.ts';

class FakeNode {
  parentNode: FakeNode | null = null;
  kids: FakeNode[] = [];
  removeChild(c: FakeNode) { const i = this.kids.indexOf(c); if (i < 0) throw new Error('NotFoundError'); this.kids.splice(i, 1); c.parentNode = null; return c; }
  insertBefore(n: FakeNode, r: FakeNode | null) {
    if (r && r.parentNode !== this) throw new Error('NotFoundError');
    const i = r ? this.kids.indexOf(r) : this.kids.length; this.kids.splice(i, 0, n); n.parentNode = this; return n;
  }
}
function setup() {
  const w = { Node: class extends FakeNode {} } as unknown as { Node: typeof FakeNode; __ccDomGuard?: { rescued: number } };
  new Function('window', DOM_GUARD_SCRIPT)(w);
  return w;
}

test('a node the translator moved: removing or inserting beside it no longer throws', () => {
  const w = setup();
  const a = new w.Node(), b = new w.Node(), stray = new w.Node();
  a.insertBefore(b, null);
  assert.equal(a.removeChild(stray), stray);
  a.insertBefore(new w.Node(), stray);
  assert.equal(a.kids.length, 2);
  assert.equal(w.__ccDomGuard?.rescued, 2);
});
test('normal calls are unchanged, and a second run does not wrap again', () => {
  const w = setup();
  const p1 = w.Node.prototype.removeChild;
  new Function('window', DOM_GUARD_SCRIPT)(w);
  assert.equal(w.Node.prototype.removeChild, p1);
  const a = new w.Node(), b = new w.Node(), c = new w.Node();
  a.insertBefore(b, null); a.insertBefore(c, b);
  assert.deepEqual(a.kids, [c, b]);
  a.removeChild(b);
  assert.deepEqual(a.kids, [c]);
  assert.equal(w.__ccDomGuard?.rescued, 0);
});
