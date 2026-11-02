import { test } from 'node:test';
import assert from 'node:assert/strict';
import { QUO_WEB, callPlan, e164, isHandheld, prettyNumber, quoDial, quoMessage } from './quo-links.ts';

// r27 consolidation: Call and Text through Quo (Quo's documented app links; the web app; tel: and sms: when Quo is off)
const PHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile/15E148';
const DESK = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130.0';

test('numbers typed any way become +1...; anything else is not callable', () => {
  assert.equal(e164('(416) 555-0177'), '+14165550177');
  assert.equal(e164('1-416-555-0177'), '+14165550177');
  assert.equal(e164('+63 917 555 0100'), '+639175550100');
  assert.equal(e164('555-0177'), null);
  assert.equal(e164(''), null);
  assert.equal(e164(null), null);
});

test('Quo\'s app links: the dialer and the composer, from the CarmaCars number', () => {
  assert.equal(quoDial('+14165550177', '+12895550100'), 'openphone://dial?number=%2B14165550177&from=%2B12895550100');
  assert.equal(quoDial('+14165550177'), 'openphone://dial?number=%2B14165550177');
  assert.equal(quoMessage('+14165550177', null, 'Hi there'), 'openphone://message?number=%2B14165550177&text=Hi+there');
});

test('what Call does: the phone app when Quo is off, the Quo app on a phone, the web app or the desktop app on a computer', () => {
  assert.deepEqual(callPlan('+14165550177', { quo: false, ua: PHONE }), { kind: 'native', href: 'tel:+14165550177' });
  assert.equal(callPlan('+14165550177', { quo: true, ua: PHONE, from: '+12895550100' }).kind, 'quo-app');
  assert.deepEqual(callPlan('+14165550177', { quo: true, ua: DESK }), { kind: 'quo-web', href: QUO_WEB });
  assert.deepEqual(callPlan('+14165550177', { quo: true, ua: DESK, desktop: 'app' }), { kind: 'quo-desktop', href: 'tel:+14165550177' });
  assert.ok(isHandheld(PHONE));
  assert.ok(!isHandheld(DESK));
});

test('numbers shown the North American way', () => {
  assert.equal(prettyNumber('+14165550177'), '(416) 555-0177');
  assert.equal(prettyNumber('+639175550100'), '+639175550100');
});
