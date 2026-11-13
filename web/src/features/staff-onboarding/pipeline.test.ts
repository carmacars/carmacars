import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { appStage, groupPipeline, staffStage, STAGES, type PipeApp } from './pipeline.ts';
import type { OnboardingRow } from './model.ts';

const app = (status: string, ai?: PipeApp['ai']): PipeApp => ({ id: status, full_name: 'Test Person', role: 'Assistant', status, score: 80, created_at: '2026-01-01T00:00:00Z', slot_starts_at: null, ai });
const staff = (o: Partial<OnboardingRow['state']> & { onboarded?: boolean }): OnboardingRow => ({ user_id: 'u', name: 'Test Staff', functions: ['fleet'], onboarded: !!o.onboarded, groups: [], marked_by: null,
  state: { member: true, academy: false, agreement: false, whatsapp: false, step: 'academy', done: false, ...o } });

test('an application is in exactly one stage', () => {
  assert.equal(appStage(app('new')), 'applied');
  assert.equal(appStage(app('below_bar')), 'applied');
  assert.equal(appStage(app('invited', { state: 'sent' })), 'ai');
  assert.equal(appStage(app('invited', { state: 'submitted' })), 'ai');
  assert.equal(appStage(app('invited', { state: 'scored' })), 'decision');
  assert.equal(appStage(app('invited')), 'booked');
  assert.equal(appStage(app('booked')), 'booked');
  assert.equal(appStage(app('interviewed')), 'decision');
  for (const s of ['declined', 'rejected', 'withdrawn', 'referred', 'hired', 'no_show']) assert.equal(appStage(app(s)), null, s);
});
test('a live call is not an AI interview', () => {
  assert.equal(appStage(app('invited', { state: 'sent', live_call: true })), 'booked');
});
test('a staff member waits at the first missing step, in the owner order', () => {
  assert.equal(staffStage(staff({})), 'agreement');
  assert.equal(staffStage(staff({ agreement: true })), 'academy');
  assert.equal(staffStage(staff({ agreement: true, academy: true })), 'whatsapp');
  assert.equal(staffStage(staff({ agreement: true, academy: true, whatsapp: true, step: 'approval' })), 'approval');
  assert.equal(staffStage(staff({ onboarded: true, agreement: true, academy: true, whatsapp: true })), 'onboarded');
  assert.equal(staffStage(staff({ exempt: true })), null);
});
test('counts add up to the people in the pipeline, in stage order', () => {
  const g = groupPipeline([app('new'), app('booked'), app('declined')], [staff({}), staff({ agreement: true, academy: true }), staff({ exempt: true })]);
  assert.equal(Object.values(g.counts).reduce((a, b) => a + b, 0), 4);
  assert.deepEqual(STAGES.map((s) => s.key), ['applied', 'ai', 'booked', 'decision', 'agreement', 'academy', 'whatsapp', 'approval', 'onboarded']);
  assert.equal(g.counts.agreement, 1); assert.equal(g.counts.whatsapp, 1); assert.equal(g.counts.applied, 1);
});
