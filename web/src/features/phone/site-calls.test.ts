import { test } from 'node:test';
import assert from 'node:assert/strict';
import { answeredBy, callRecordingsUrl, pickRecording, ringBrowsersTwiml } from './twilio.ts';
import { EVENTS, parseQuoEvent, transcriptText } from './webhook.ts';
import { readCallMedia } from './quo-api.ts';
import { callState, type LiveCall } from '../caller/model.ts';

// r48 (2995): site calls open the pop-up, record incoming calls, and every call's recording, transcript and summary.
const ID = 'staff_' + '1'.repeat(32);
const PARENT = 'CA' + 'a'.repeat(32);
const OURS = '+12895550100';
const THEM = '+16475550123';

test('ring: recorded dual channel and each browser says when it answered', () => {
  const x = ringBrowsersTwiml({ ring: [{ identity: ID, who: 'Maya' }], callerId: OURS, actionUrl: 'https://x.test/end', answeredUrl: 'https://x.test/ans', recordingUrl: 'https://x.test/rec' });
  assert.match(x, /<Dial [^>]*record="record-from-answer-dual" recordingStatusCallback="https:\/\/x\.test\/rec"/);
  assert.match(x, /<Client statusCallbackEvent="answered" statusCallback="https:\/\/x\.test\/ans" statusCallbackMethod="POST"><Identity>/);
  const plain = ringBrowsersTwiml({ ring: [{ identity: ID, who: 'Maya' }], callerId: OURS, actionUrl: 'https://x.test/end', recordingUrl: null });
  assert.doesNotMatch(plain, /record=|statusCallback=/);
});

test('ring answered: the parent call and the staff member, only when answered', () => {
  assert.deepEqual(answeredBy({ ParentCallSid: PARENT, CallStatus: 'in-progress', To: `client:${ID}` }), { parent: PARENT, user: '11111111-1111-1111-1111-111111111111' });
  assert.equal(answeredBy({ ParentCallSid: PARENT, CallStatus: 'ringing', To: `client:${ID}` }), null);
  assert.equal(answeredBy({ ParentCallSid: 'nope', CallStatus: 'in-progress' }), null);
  assert.deepEqual(answeredBy({ ParentCallSid: PARENT, CallStatus: 'answered', To: '+16475550123' }), { parent: PARENT, user: null });
});

test('backfill at Twilio: the call recordings list and the longest finished recording', () => {
  assert.equal(callRecordingsUrl('AC' + '0'.repeat(32), PARENT), `https://api.twilio.com/2010-04-01/Accounts/AC${'0'.repeat(32)}/Calls/${PARENT}/Recordings.json`);
  assert.throws(() => callRecordingsUrl('AC1', 'bad'));
  const re = (c: string) => 'RE' + c.repeat(32);
  assert.deepEqual(pickRecording({ recordings: [{ sid: re('1'), duration: '12', status: 'completed' }, { sid: re('2'), duration: '95', status: 'completed' }, { sid: re('3'), duration: '300', status: 'processing' }] }),
    { sid: re('2'), seconds: 95 });
  assert.equal(pickRecording({ recordings: [] }), null);
  assert.equal(pickRecording(null), null);
});

// Quo's 2026-03-30 envelope: data.resource and data.context
const env = (type: string, resource: Record<string, unknown>) => ({ id: 'EV1', type, apiVersion: '2026-03-30',
  data: { resource, context: { phoneNumberId: 'PN1', conversationId: 'CN1', userId: 'US1', participants: { workspace: [OURS], external: [THEM], resolution: 'available' } } } });

test('Quo: the webhook subscribes to every call and text event we read', () => {
  for (const e of ['call.ringing', 'call.completed', 'call.recording.completed', 'call.transcript.completed', 'call.summary.completed', 'message.received', 'message.delivered'])
    assert.ok(EVENTS.includes(e), e);
});

test('Quo: each event is read', () => {
  const ring = parseQuoEvent(env('call.ringing', { id: 'AC1', direction: 'incoming', createdAt: '2026-11-14T10:00:00Z' }), 'D1', OURS)!;
  assert.equal(ring.type, 'call.ringing'); assert.equal(ring.call_id, 'AC1'); assert.equal(ring.direction, 'in'); assert.equal(ring.their_number, THEM); assert.equal(ring.missed, false);
  const done = parseQuoEvent(env('call.completed', { id: 'AC1', direction: 'incoming', status: 'completed', answeredAt: '2026-11-14T10:00:05Z', completedAt: '2026-11-14T10:03:00Z', duration: 175.4 }), 'D2', OURS)!;
  assert.equal(done.duration, 175); assert.equal(done.missed, false); assert.equal(done.answered_at, '2026-11-14T10:00:05Z');
  const missed = parseQuoEvent(env('call.completed', { id: 'AC2', direction: 'incoming', status: 'no-answer' }), 'D3', OURS)!;
  assert.equal(missed.missed, true);
  const rec = parseQuoEvent(env('call.recording.completed', { id: 'AC1', direction: 'incoming', recordings: [{ id: 'RC1', url: 'https://files.example.test/r.mp3', duration: 170, type: 'audio/mpeg' }] }), 'D4', OURS)!;
  assert.deepEqual(rec.recordings, [{ id: 'RC1', url: 'https://files.example.test/r.mp3', duration: 170, type: 'audio/mpeg' }]);
  const tr = parseQuoEvent(env('call.transcript.completed', { callId: 'AC1', dialogue: [{ userId: 'US1', identifier: OURS, content: 'CarmaCars, how can I help?', start: 0, end: 2 }, { identifier: THEM, content: 'I want to extend.', start: 2, end: 4 }] }), 'D5', OURS)!;
  assert.equal(tr.call_id, 'AC1');
  assert.deepEqual(tr.transcript.map((d) => d.who), ['us', 'them']);
  const sum = parseQuoEvent(env('call.summary.completed', { callId: 'AC1', summary: ['The renter asked to extend by two days.'], nextSteps: ['Send the change.'] }), 'D6', OURS)!;
  assert.equal(sum.call_id, 'AC1'); assert.deepEqual(sum.summary, ['The renter asked to extend by two days.']); assert.deepEqual(sum.next_steps, ['Send the change.']);
  const msg = parseQuoEvent({ id: 'EV2', type: 'message.received', data: { resource: { id: 'AM1', text: 'Hi', direction: 'incoming' }, context: { senderIdentifier: THEM, recipientIdentifiers: [OURS] } } }, 'D7', OURS)!;
  assert.equal(msg.text, 'Hi'); assert.equal(msg.their_number, THEM); assert.equal(msg.direction, 'in');
  const del = parseQuoEvent({ id: 'EV3', type: 'message.delivered', data: { resource: { id: 'AM2', text: 'Yes', direction: 'outgoing', status: 'delivered' }, context: { senderIdentifier: OURS, recipientIdentifiers: [THEM] } } }, 'D8', OURS)!;
  assert.equal(del.direction, 'out'); assert.equal(del.their_number, THEM); assert.equal(del.status, 'delivered');
});

test('Quo backfill: recordings, transcript with speakers and summary read from the API answers', () => {
  const m = readCallMedia({ data: [{ id: 'RC1', url: 'https://files.example.test/r.mp3', duration: 61.6, type: 'audio/mpeg', status: 'completed' }, { id: 'RC2', url: 'https://x.test/p', status: 'processing' }] },
    { data: { status: 'completed', dialogue: [{ userId: 'US1', content: 'Hello' }, { identifier: THEM, content: 'Hi' }, { content: '' }] } },
    { data: { status: 'completed', summary: ['Asked about the deposit.'], nextSteps: ['Call back.'] } });
  assert.equal(m.recordings.length, 1); assert.equal(m.recordings[0]!.duration, 62);
  assert.deepEqual(m.transcript.map((d) => [d.who, d.text]), [['us', 'Hello'], ['them', 'Hi']]);
  assert.deepEqual(m.summary, ['Asked about the deposit.']); assert.deepEqual(m.next_steps, ['Call back.']);
  assert.deepEqual(readCallMedia(null, null, null), { recordings: [], transcript: [], summary: [], next_steps: [] });
  assert.deepEqual(readCallMedia(null, null, { data: { status: 'in-progress', summary: ['x'] } }).summary, []);
});

test('the AI summary prompt: a site call has no speaker label', () => {
  assert.equal(transcriptText([{ who: 'call', text: 'Both sides.' }]), 'Both sides.');
  assert.equal(transcriptText([{ who: 'us', text: 'Hi' }, { who: 'them', text: 'Hello' }]), 'CarmaCars: Hi\nCaller: Hello');
});

test('pop-up: a call placed from the site says so', () => {
  const c = { id: 'x', direction: 'out', live: true, answered_at: null, missed: false } as unknown as LiveCall;
  assert.equal(callState(c), 'Your call: on now');
  assert.equal(callState({ ...c, live: false }), 'Call ended');
  assert.equal(callState({ ...c, direction: 'in' }), 'Ringing now');
});
