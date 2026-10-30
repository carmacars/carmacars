import { test } from 'node:test';
import assert from 'node:assert/strict';
import { byStage, followupWords, type PipelineLead } from './model.ts';

const lead = (o: Partial<PipelineLead>): PipelineLead => ({ id: 'x', kind: 'owner_program', name: 'A', business_name: null, email: null, phone: null, vehicle: null, stage: 'new', stage_at: null,
  source: 'website', note: null, message: null, created_at: '2026-11-01T00:00:00Z', assignee: null, followup_step: 0, followup_next_at: null, followup_stop_reason: null,
  replied_at: null, referred_by: null, owner_id: null, ...o });

test('every stage is a column, in order', () => {
  const s = byStage([lead({ stage: 'signed' }), lead({ stage: 'new' })]);
  assert.equal(s.length, 7);
  assert.equal(s[0]!.leads.length, 1);
  assert.equal(s[4]!.stage, 'signed');
});
test('the follow-up line', () => {
  assert.match(followupWords(lead({ followup_next_at: '2026-11-03T00:00:00Z', followup_step: 1 }), [0, 2, 5, 10], () => 'Nov 3'), /2 of 4 on Nov 3/);
  assert.equal(followupWords(lead({ followup_stop_reason: 'They replied' }), [0], () => ''), 'Follow-ups stopped: They replied');
});
