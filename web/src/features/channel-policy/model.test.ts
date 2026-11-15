// r48 (2971): the channel of each message type in plain words.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CHANNEL_OPTIONS, fixedLabel, policyNow, textsSaved, type PolicyType } from './model.ts';

const row = (x: Partial<PolicyType>): PolicyType => ({ code: 'renter_booking_confirmed', label: 'Booking confirmed', audience: 'renter', urgent: false, channel: 'email', chosen: false, default: 'email', texts_30d: 0, editable: true, ...x });

test('off (the SES sandbox): every type says as before', () => {
  assert.match(policyNow(row({}), false), /^As before/);
});

test('on: the default, an urgent type, an Admin\'s change', () => {
  assert.equal(policyNow(row({}), true), 'Email only (a text only when there is no email or it bounced) (default)');
  assert.equal(policyNow(row({ urgent: true, channel: 'both', default: 'both' }), true), 'Text and email (the person chooses) (urgent: keeps the text)');
  assert.equal(policyNow(row({ channel: 'text', chosen: true }), true), 'Text only (changed)');
});

test('the texts the email-only types sent in the last 30 days', () => {
  assert.equal(textsSaved({ production_ready: true, fixed: [], types: [row({ texts_30d: 12 }), row({ channel: 'both', texts_30d: 40 }), row({ texts_30d: 3 })] }), 15);
});

test('the three channels, email first; a fixed kind in words', () => {
  assert.deepEqual(CHANNEL_OPTIONS.map(([v]) => v), ['email', 'both', 'text']);
  assert.equal(fixedLabel('deposit_link'), 'Deposit link');
  assert.equal(fixedLabel('owner_payout_code'), 'Owner payout code');
});
