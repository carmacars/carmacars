import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  DISMISS_KEEP_MS, balanceWords, bookingHref, bookingWords, callState, callerTitle, depositWords, noteProblem, pruneDismissed, renterHref, visibleCalls,
  type CallerRenter, type LiveCall
} from './model.ts';

// The caller pop-up and renter notes (migration 0800): what the pop-up says about a call and a renter, which calls it
// shows, and that every portal frame and read is wired (the Admin's and customer service's).
const renter: CallerRenter = {
  id: 'r1', name: 'Maya Patel', identity_status: 'verified', is_blocked: false,
  booking: { number: 'CC-10482', status: 'on_rent', car: '2024 Mercedes-Benz C 300', pickup_at: '2026-11-07T15:00:00Z', return_at: '2026-11-10T15:00:00Z', active: true },
  balance: { owed_cents: 21240, rental_cents: 21240, charges_cents: 0, overdue: true },
  deposit: { required_cents: 100000, held_cents: 100000, how: 'card_hold', state: 'held' }, requests: [], notes: [], notes_count: 0
};
const call = (over: Partial<LiveCall> = {}): LiveCall => ({ id: 'a1', thread_id: 't1', number: '+14165550142', display: '416-555-0142', at: '2026-11-08T15:00:00Z',
  answered_at: null, ended_at: null, missed: false, live: true, kind: 'renter', who: 'Maya Patel', lead_id: null, owner_id: null, renter, ...over });

test('who is calling: the renter by name, an unknown number as Unknown caller', () => {
  assert.equal(callerTitle(call()), 'Maya Patel');
  assert.equal(callerTitle(call({ kind: 'unknown', renter: null, who: '416-555-0999' })), 'Unknown caller');
  assert.equal(callerTitle(call({ kind: 'lead', renter: null, who: 'Una Known' })), 'Una Known');
});

test('the state of the call', () => {
  assert.equal(callState(call()), 'Ringing now');
  assert.equal(callState(call({ answered_at: '2026-11-08T15:00:05Z' })), 'On the phone now');
  assert.equal(callState(call({ live: false, missed: true })), 'Missed call');
  assert.equal(callState(call({ live: false, ended_at: '2026-11-08T15:02:00Z' })), 'Call ended');
});

test('the renter lines: booking, balance, deposit', () => {
  assert.equal(bookingWords(renter), 'On rent: CC-10482, 2024 Mercedes-Benz C 300');
  assert.equal(bookingWords({ ...renter, booking: { ...renter.booking!, active: false } }), 'Next: CC-10482, 2024 Mercedes-Benz C 300');
  assert.equal(bookingWords({ ...renter, booking: null }), 'No active or upcoming booking');
  assert.equal(balanceWords(renter.balance), '$212.40 owed, overdue');
  assert.equal(balanceWords({ owed_cents: 0, rental_cents: 0, charges_cents: 0, overdue: false }), 'Nothing owed');
  assert.equal(depositWords(renter.deposit), '$1,000.00 held on the card');
  assert.equal(depositWords({ required_cents: 50000, held_cents: 0, how: null, state: 'not_taken' }), 'Not taken yet ($500.00)');
  assert.equal(depositWords({ required_cents: 0, held_cents: 0, how: null, state: 'none' }), 'None needed');
  assert.equal(depositWords(null), 'No booking');
});

test('closed calls stay hidden for two hours, newest call first', () => {
  const now = Date.parse('2026-11-08T15:00:00Z');
  const calls = [call({ id: 'a', at: '2026-11-08T14:00:00Z' }), call({ id: 'b', at: '2026-11-08T14:59:00Z' }), call({ id: 'c', at: '2026-11-08T14:30:00Z' })];
  assert.deepEqual(visibleCalls(calls, { c: now }).map((c) => c.id), ['b', 'a']);
  assert.deepEqual(Object.keys(pruneDismissed({ old: now - DISMISS_KEEP_MS - 1, fresh: now - 1000, bad: 'x' as unknown as number }, now)), ['fresh']);
});

test('links go to the person\'s own portal', () => {
  assert.equal(renterHref('admin', 'r1'), '/admin/renters/r1');
  assert.equal(renterHref('va', 'r1'), '/staff/renters?id=r1');
  assert.equal(bookingHref('va', 'CC-1'), '/staff/bookings/CC-1');
});

test('a note is 1 to 4,000 characters, as the database says', () => {
  assert.equal(noteProblem('   '), 'Write the note');
  assert.equal(noteProblem('x'.repeat(4001)), 'Keep a note under 4,000 characters');
  assert.equal(noteProblem(' Called about the return '), null);
  const sql = readFileSync(new URL('../../../../supabase/migrations/0800_r34n_caller_popup.sql', import.meta.url), 'utf8');
  assert.match(sql, /length\(btrim\(body\)\) between 1 and 4000/);
});

test('the pop-up is in the Admin frame and in customer service\'s, and its reads go through the phone route', () => {
  const src = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');
  assert.match(src('../../app/admin/layout.tsx'), /<CallerPopup portal="admin" \/>/);
  assert.match(src('../../app/staff/layout.tsx'), /held\.includes\('cs'\) \? <CallerPopup portal="va" \/>/);
  const route = src('../../app/api/staff/phone/route.ts');
  for (const n of ['caller_live', 'renter_notes', 'renter_note_add', 'renter_note_remove', 'caller_open']) assert.ok(route.includes(`'${n}'`), n);
  assert.match(src('../../app/admin/renters/[id]/page.tsx'), /<RenterNotes /);
  assert.match(src('../renters-page/RentersPage.tsx'), /<RenterNotes /);
  assert.match(src('./CallerPopup.tsx'), /poller\(CALLER_POLL_MS\)/);
});
