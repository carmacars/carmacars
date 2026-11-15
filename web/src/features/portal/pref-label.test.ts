import { test } from 'node:test';
import assert from 'node:assert/strict';
import { noTags, prefLabel } from './pref-label.ts';

test('an optional email is named without merge tags', () => {
  assert.equal(prefLabel('renter_comeback_1w', '{{discount_percent}}% off your next CarmaCars rental'), 'A discount a week after your rental');
  assert.equal(prefLabel('some_new_code', '{{discount_percent}}% off your next rental, {{first_name}}'), 'off your next rental');
  assert.equal(prefLabel('renter_rewards_waiting', 'Your {{points_balance}} CarmaCars points are waiting'), 'Rewards: your points are waiting');
  for (const s of ['You are {{points_to_next}} points from {{next_tier}}', '{{holiday_name}}: {{reward_pct}} off for you', 'Your birthday reward is waiting: {{reward_pct}} off'])
    assert.ok(!prefLabel('x', s).includes('{{'));
});

test('a notice never shows a leftover tag', () => {
  assert.equal(noTags('Code {{discount_code}}, good until {{discount_expires}}.'), 'Code, good until.');
  assert.equal(noTags('Plain text'), 'Plain text');
});
