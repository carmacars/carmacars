import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addNonce, nonceRewriter } from './nonce-stream.ts';

const PAGE = '<!DOCTYPE html><html><head><script id="a">1</script><script>2</script><scripts>no</scripts></head>'
  + '<body><p>&lt;script&gt; as text</p><script src="/x.js"></script><script\n>3</script><template><script async>4</script></template></body></html>';

test('the whole page: every <script> gets the nonce, nothing else changes', () => {
  const out = addNonce(PAGE, 'N');
  assert.equal((out.match(/<script nonce="N"/g) ?? []).length, 5);
  assert.ok(out.includes('<scripts>no</scripts>'));
  assert.equal(out.replace(/ nonce="N"/g, ''), PAGE);
});

test('in pieces: the same answer as the whole page at every split, even inside "<script"', () => {
  const whole = addNonce(PAGE, 'N');
  for (let a = 0; a < PAGE.length; a++) {
    const r = nonceRewriter('N');
    assert.equal(r.push(PAGE.slice(0, a)) + r.push(PAGE.slice(a)) + r.end(), whole, `split at ${a}`);
  }
  // one character at a time
  const r = nonceRewriter('N');
  let out = '';
  for (const ch of PAGE) out += r.push(ch);
  assert.equal(out + r.end(), whole);
});

test('only a "<" near the end is held back; the rest is sent at once', () => {
  const r = nonceRewriter('N');
  assert.equal(r.push('<p>hello there, all of you'), '<p>hello there, all of you');
  assert.equal(r.push(' and <scr'), ' and ');
  assert.equal(r.push('ipt>x'), '<script nonce="N">x');
  assert.equal(r.end(), '');
});
