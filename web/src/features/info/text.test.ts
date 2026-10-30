import { test } from 'node:test';
import assert from 'node:assert/strict';
import { INFO, infoText } from './text.ts';

// Release 21b, item 7: every "i" is short, plain and complete.
test('every info text is short, a sentence, no long dash, no placeholder', () => {
  for (const [k, t] of Object.entries(INFO)) {
    assert.ok(t.length >= 20 && t.length <= 260, `${k}: ${t.length} characters`);
    assert.match(t, /[.)]$/, `${k}: ends a sentence`);
    assert.doesNotMatch(t, /[–—]|TODO|\{\{/, `${k}: long dash or placeholder`);
  }
});
test('the policy figures match the facts', () => {
  assert.match(infoText('deductible')!, /\$2,500/);
  assert.match(infoText('young_driver')!, /\$35 a day aged 18 to 20, \$20 a day aged 21 to 25/);
  assert.match(infoText('coverage')!, /OPCF 27/);
  assert.equal(infoText('nope'), undefined);
});
