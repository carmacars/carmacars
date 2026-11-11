import { test } from 'node:test';
import assert from 'node:assert/strict';
import { meetLinkOf, meetRequest, type MeetCall } from './event.ts';

const call: MeetCall = { id: '11111111-2222-3333-4444-555555555555', sync: 'create', event_id: null, starts_at: '2031-03-02T15:00:00Z', ends_at: '2031-03-02T15:15:00Z', title: 'Interview call: CS (Remy)', email: 'remy@example.test' };

test('a booked call creates an event with a Google Meet conference, no Google invitation email', () => {
  const r = meetRequest(call, 'primary')!;
  assert.equal(r.method, 'POST');
  assert.equal(r.url, 'https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1&sendUpdates=none');
  const b = r.body as { conferenceData: { createRequest: { requestId: string; conferenceSolutionKey: { type: string } } }; attendees: Array<{ email: string }>; start: { dateTime: string } };
  assert.equal(b.conferenceData.createRequest.conferenceSolutionKey.type, 'hangoutsMeet');
  assert.equal(b.conferenceData.createRequest.requestId, `cc-${call.id}`);
  assert.deepEqual(b.attendees, [{ email: 'remy@example.test' }]);
  assert.equal(b.start.dateTime, '2031-03-02T15:00:00Z');
});

test('a moved call moves the same event; a cancelled one deletes it', () => {
  const m = meetRequest({ ...call, sync: 'update', event_id: 'ev/1' }, 'team@example.test')!;
  assert.equal(m.method, 'PATCH');
  assert.equal(m.url, 'https://www.googleapis.com/calendar/v3/calendars/team%40example.test/events/ev%2F1?conferenceDataVersion=1&sendUpdates=none');
  assert.deepEqual(Object.keys(m.body!), ['start', 'end']);
  assert.equal(meetRequest({ ...call, sync: 'delete', event_id: 'ev1' }, 'primary')!.method, 'DELETE');
  assert.equal(meetRequest({ ...call, sync: 'delete', event_id: null }, 'primary'), null);
  assert.equal(meetRequest({ ...call, starts_at: null }, 'primary'), null);
});

test('only a real Meet link is taken from the answer', () => {
  assert.equal(meetLinkOf({ hangoutLink: 'https://meet.google.com/abc-defg-hij' }), 'https://meet.google.com/abc-defg-hij');
  assert.equal(meetLinkOf({ conferenceData: { entryPoints: [{ entryPointType: 'phone', uri: 'tel:+1' }, { entryPointType: 'video', uri: 'https://meet.google.com/xyz-abcd-efg' }] } }), 'https://meet.google.com/xyz-abcd-efg');
  assert.equal(meetLinkOf({ hangoutLink: 'https://evil.example.test/x' }), null);
  assert.equal(meetLinkOf(null), null);
});
