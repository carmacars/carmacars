import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { liveWithoutContact, visitorWithoutContact } from './contact.ts';
import type { LiveData, Visitor } from './staff.ts';

// Release 26: the Visitors page with Show contact off sends and shows no phone or email, not even a name that is one.
const v = (o: Partial<Visitor>): Visitor => ({ id: 's1', visitor_id: 'b1', who: 'Visitor in Toronto', known: false, renter_id: null, email: null, identified_by: null, consent: 'analytics',
  city: 'Toronto', region: 'ON', device: 'Phone', referrer: null, utm_source: null, utm_campaign: null, started_at: '2026-11-06T12:00:00Z', last_seen_at: '2026-11-06T12:05:00Z',
  page_views: 3, visit_number: 1, current_path: '/', current_page: 'Home', car: null, vehicle_id: null, booking_number: null, cars_viewed: 0, signals: [], chat: null, ...o });

describe('Show contact off (Visitors page)', () => {
  it('takes out the email, what was typed (phone and email) and a named visitor\'s phone and email; the names stay', () => {
    const out = visitorWithoutContact(v({ who: 'Erin E.', email: 'erin@example.test',
      captured: { name: 'Erin Example', email: 'erin@example.test', phone: '4165550142', form: 'booking request', at: '2026-11-06T12:01:00Z', done: false, renter_id: null, email_confirmed: false },
      label: { name: 'Erin', phone: '(416) 555-0142', email: 'erin@example.test', note: 'asked about the van', source: 'staff', by: 'Lima', at: '2026-11-06T12:02:00Z' } }));
    assert.equal(out.who, 'Erin E.');
    assert.equal(out.captured?.name, 'Erin Example');
    assert.equal(out.label?.name, 'Erin');
    assert.doesNotMatch(JSON.stringify(out), /example\.test|555|0142/);
  });
  it('a visitor known only by an email or a phone shows as a visitor in their city', () => {
    assert.equal(visitorWithoutContact(v({ who: 'erin@example.test' })).who, 'Visitor in Toronto');
    assert.equal(visitorWithoutContact(v({ who: '+1 416 555 0142', city: null })).who, 'Visitor');
    assert.equal(visitorWithoutContact(v({ captured: { name: 'erin@example.test', email: null, phone: null, form: 'contact', at: '', done: true, renter_id: null, email_confirmed: null } })).captured?.name, null);
  });
  it('the whole read: every visit, the hot list and the signals', () => {
    const d = { live_minutes: 5, tracking: true, at: '', now: [v({ email: 'a@example.test' })], signals: [{ kind: 'x', label: 'x', at: '', who: 'b@example.test' }], most_viewed: [],
      today: { sessions: 1, known: 0, chats: 0 }, hot: [{ id: 's1', who: 'c@example.test', score: 70, hot_at: '', reasons: [], online: true, renter_id: null, acted: false }] } as LiveData;
    assert.doesNotMatch(JSON.stringify(liveWithoutContact(d)), /example\.test/);
  });
});
