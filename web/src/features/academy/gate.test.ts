import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { currentStep, gateWords, opensWhileHeld, opensWhileUnsigned, profileHref, signHref, stepWords, type GateState, type WelcomeStep } from './gate.ts';

// The academy gate (0802): what a held person still opens, the Welcome steps of a new hire, the Admin's words for the gate,
// and the content of releases 33 and 34 (supabase/seed/academy/r34.mjs): a quiz per section, on every role that uses it,
// written from guide chapters that exist, the migration block up to date.
test('a held person opens only the academy, the guide, the profile and Welcome', () => {
  for (const p of ['/staff/academy', '/staff/academy/cs/trip-rules', '/staff/guide', '/staff/profile', '/staff/field/profile', '/staff/welcome', '/staff/no-access', '/staff/field/training', '/staff/field/pay']) assert.ok(opensWhileHeld(p), p);
  for (const p of ['/staff', '/staff/tasks', '/staff/bookings/CC-1', '/staff/renters', '/staff/welcomeback', '/staff/field']) assert.ok(!opensWhileHeld(p), p);
  assert.match(readFileSync(new URL('../../server/door.ts', import.meta.url), 'utf8'), /academy_locked && !ACADEMY_OPEN\.test\(next\)\) redirect\('\/staff\/welcome'\)/);
});

test('Welcome: the step to do now, in order', () => {
  const steps: WelcomeStep[] = [{ key: 'welcome', done: true }, { key: 'profile', done: false, address: false, phone: true, preferred_name: 'Sam' }, { key: 'academy', done: false, passed: 2, sections: 9 }, { key: 'tasks', done: false, tasks: [{ id: 't', title: 'Read your guide', detail: null, done: false }] }];
  assert.equal(currentStep(steps), 'profile');
  assert.equal(stepWords(steps[1]!), 'Add your home address.');
  assert.equal(stepWords(steps[2]!), '2 of 9 sections passed. Each quiz passes at 80%, and you can retake it.');
  assert.equal(stepWords(steps[3]!), '1 left.');
  assert.equal(currentStep(steps.map((s) => ({ ...s, done: true }))), null);
  assert.equal(profileHref('field'), '/staff/field/profile');
});

test('1060: the academy first, then the agreement, then access', () => {
  for (const p of ['/staff/sign', '/staff/sign/abc', '/staff/field/sign', '/staff/documents/x', '/staff/welcome', '/staff/academy', '/staff/profile']) assert.ok(opensWhileUnsigned(p), p);
  for (const p of ['/staff', '/staff/bookings/CC-1', '/staff/field', '/staff/signals']) assert.ok(!opensWhileUnsigned(p), p);
  // signing is not open while the academy holds the person
  assert.ok(!opensWhileHeld('/staff/sign'));
  assert.equal(signHref('field'), '/staff/field/sign');
  assert.match(stepWords({ key: 'agreement', done: false, state: 'sent', waiting_for_academy: true }), /once the academy is passed/);
  assert.match(stepWords({ key: 'agreement', done: false, state: 'sent' }), /^Ready to sign/);
  assert.match(stepWords({ key: 'team', done: false, open: true, groups: [{ key: 'team', name: 'CarmaCars Team', url: 'https://chat.whatsapp.com/x' }] }), /I joined/);
  assert.match(readFileSync(new URL('../../server/door.ts', import.meta.url), 'utf8'), /agreement_locked && !AGREEMENT_OPEN\.test\(next\)\) redirect\('\/staff\/welcome'\)/);
});

test('the Admin\'s words for the gate', () => {
  const g: GateState = { user_id: 'u', locked: true, done: false, passed: 3, sections: 10, lock_from: null, waiver: null };
  assert.match(gateWords(g), /^Held: 3 of 10/);
  assert.match(gateWords({ ...g, locked: false, waiver: { reason: 'Experienced', at: '2026-11-08T12:00:00Z', by: 'Ada' } }), /^Waived by Ada: Experienced\./);
  assert.match(gateWords({ ...g, locked: false, done: true, passed: 10 }), /^Passed: 10 of 10/);
});

test('the content of releases 33 and 34: a quiz per section, every role, real guide chapters, no vendor names', async () => {
  const { SECTIONS } = await import(new URL('../../../../supabase/seed/academy/r34.mjs', import.meta.url).href) as { SECTIONS: Array<{ slug: string; title: string; paths: string[]; guides: string[]; lessons: unknown[]; quiz: Array<{ options: string[]; answer: number }> }> };
  const roles = new Set(SECTIONS.flatMap((s) => s.paths));
  for (const r of ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field', 'admin']) assert.ok(roles.has(r), `no new section for ${r}`);
  for (const s of SECTIONS) {
    assert.ok(s.lessons.length > 0 && s.quiz.length >= 2, `${s.slug}: lessons and a quiz`);
    assert.ok(s.guides.length > 0, `${s.slug}: written from a guide chapter`);
    assert.doesNotMatch(JSON.stringify({ ...s, guides: [] }), /google|stripe|\bquo\b|openphone|cloudflare|claude|[–—]/i, s.slug);
  }
  assert.ok(SECTIONS.find((s) => s.slug === 'new-r34-caller-notes')?.paths.includes('cs'), 'the caller panel is on customer service\'s path');
  const root = fileURLToPath(new URL('../../../../', import.meta.url));
  assert.match(execFileSync('node', ['supabase/seed/0802_gen_academy.mjs', '--check'], { cwd: root, encoding: 'utf8' }), /up to date/);
});
