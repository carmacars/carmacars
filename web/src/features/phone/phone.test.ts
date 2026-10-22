import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseQuoEvent, signQuo, signQuoLegacy, transcriptText, verifyQuoSignature, EVENTS } from './webhook.ts';
import { SAMPLES, OUR, THEM } from './samples.ts';
import { renderTemplate, templateProblem, segments, SAMPLE_VARS } from './templates.ts';
import { ensureWebhook, listNumbers, sendText, QuoError } from './quo-api.ts';

// Quo (migration 0085): signatures, the sample payloads of Quo's documentation, the templates and the API client.
const SECRET = 'whsec_' + Buffer.from('a test signing secret of 32 bytes!').toString('base64');
const hdr = (h: Record<string, string>) => (n: string) => h[n.toLowerCase()] ?? null;

test('signature (current scheme): a signed delivery passes, a changed body, another key, an old timestamp or no header fail', async () => {
  const raw = JSON.stringify(SAMPLES.messageReceived);
  const now = 1_800_000_000;
  const h = await signQuo(raw, SECRET, 'msg_1', now);
  assert.deepEqual(await verifyQuoSignature(raw, hdr(h), [SECRET], now), { ok: true, scheme: 'current', id: 'msg_1' });
  assert.equal((await verifyQuoSignature(raw + ' ', hdr(h), [SECRET], now)).ok, false);
  assert.equal((await verifyQuoSignature(raw, hdr(h), ['whsec_' + Buffer.from('another key entirely, 32 bytes!!').toString('base64')], now)).ok, false);
  assert.equal((await verifyQuoSignature(raw, hdr(h), [SECRET], now + 301)).reason, 'timestamp');
  assert.equal((await verifyQuoSignature(raw, hdr({}), [SECRET], now)).reason, 'no signature header');
  assert.equal((await verifyQuoSignature(raw, hdr(h), [undefined, ''], now)).reason, 'no secret');
  // several signatures (a rotation): any v1 entry may match; the previous key is accepted too
  const two = { ...h, 'webhook-signature': `v1,AAAA ${h['webhook-signature']}` };
  assert.equal((await verifyQuoSignature(raw, hdr(two), ['whsec_' + Buffer.from('old key').toString('base64'), SECRET], now)).ok, true);
});

test('signature (legacy openphone-signature): hmac;1;<ms>;<base64> over "<ms>.<body>"', async () => {
  const raw = JSON.stringify(SAMPLES.legacyMessage);
  const secret = Buffer.from('legacy signing secret').toString('base64');
  const ms = 1_800_000_000_000;
  const h = await signQuoLegacy(raw, secret, ms);
  assert.match(h['openphone-signature']!, /^hmac;1;1800000000000;[A-Za-z0-9+/=]+$/);
  assert.equal((await verifyQuoSignature(raw, hdr(h), [secret], ms / 1000)).scheme, 'legacy');
  assert.equal((await verifyQuoSignature('{}', hdr(h), [secret], ms / 1000)).ok, false);
});

test('payloads: a text received and delivered (who, direction, text, ids)', () => {
  const r = parseQuoEvent(SAMPLES.messageReceived, 'wh_1', OUR)!;
  assert.equal(r.event_id, 'wh_1');
  assert.deepEqual([r.type, r.quo_id, r.direction, r.their_number, r.text, r.status, r.phone_number_id, r.conversation_id], ['message.received', 'AC-message', 'in', THEM, 'hello', 'received', 'PN123', 'CN123']);
  const d = parseQuoEvent(SAMPLES.messageDelivered, null, OUR)!;
  assert.deepEqual([d.event_id, d.direction, d.their_number, d.status], ['EV2', 'out', THEM, 'delivered']);
  const f = parseQuoEvent(SAMPLES.messageFailed, null, OUR)!;
  assert.deepEqual([f.status, f.error_code, f.their_number], ['failed', '30006', THEM]);
});

test('payloads: calls (ringing, answered and completed, missed, recording, summary, transcript, voicemail)', () => {
  const ring = parseQuoEvent(SAMPLES.callRinging, null, OUR)!;
  assert.deepEqual([ring.quo_id, ring.direction, ring.their_number, ring.missed], ['AC-call', 'in', THEM, false]);
  const done = parseQuoEvent(SAMPLES.callCompleted, null, OUR)!;
  assert.deepEqual([done.status, done.duration, done.answered_at, done.missed], ['answered', 55, '2026-04-13T12:00:00.000Z', false]);
  const miss = parseQuoEvent(SAMPLES.callMissed, null, OUR)!;
  assert.deepEqual([miss.quo_id, miss.direction, miss.missed, miss.status], ['AC-call-missed', 'in', true, 'missed']);
  const rec = parseQuoEvent(SAMPLES.callRecording, null, OUR)!;
  assert.equal(rec.recordings[0]!.url, 'https://recordings.example.com/REabc123.mp3');
  const sum = parseQuoEvent(SAMPLES.callSummary, null, OUR)!;
  assert.deepEqual([sum.quo_id, sum.summary, sum.next_steps], ['AC-call', ['Customer asked for pricing details.'], ['Send follow-up email.']]);
  const tr = parseQuoEvent(SAMPLES.callTranscript, null, OUR)!;
  assert.equal(tr.quo_id, 'AC-call');
  assert.deepEqual(tr.transcript.map((x) => x.who), ['us', 'them']);
  assert.equal(transcriptText(tr.transcript), 'CarmaCars: Thanks for calling, how can I help?\nCaller: Hi, I wanted to ask about pricing.');
  const vm = parseQuoEvent(SAMPLES.callVoicemail, null, OUR)!;
  assert.deepEqual([vm.quo_id, vm.voicemail_text?.slice(0, 10), vm.voicemail_url, vm.their_number], ['AC-call-missed', 'Hi, leavin', 'https://recordings.example.com/VM123.mp3', THEM]);
});

test('payloads: no recording on the line (the owner\'s choice): a completed call without recordings, summary or transcript reads cleanly', () => {
  const done = parseQuoEvent(SAMPLES.callCompleted, null, OUR)!;
  assert.deepEqual([done.recordings, done.summary, done.transcript, done.voicemail_text], [[], [], [], null]);
});

test('payloads: legacy shapes (data.object) and junk', () => {
  const m = parseQuoEvent(SAMPLES.legacyMessage, null, OUR)!;
  assert.deepEqual([m.event_id, m.direction, m.their_number, m.text], ['EVL1', 'in', THEM, 'Is the Civic free this weekend?']);
  const c = parseQuoEvent(SAMPLES.legacyCallNoAnswer, null, OUR)!;
  assert.deepEqual([c.missed, c.their_number, c.voicemail_url], [true, THEM, 'https://example.com/vm.mp3']);
  assert.equal(parseQuoEvent({ nothing: true }), null);
  assert.equal(parseQuoEvent('x'), null);
  assert.ok(EVENTS.includes('call.missed') && EVENTS.includes('message.received') && EVENTS.length === 13);
});

test('templates: the defaults pass, the rules refuse long dashes, a missing brand and unknown placeholders; rendering fills and drops', () => {
  const missed = 'Sorry we missed your call. How can we help? Reply here, or book at carmacars.ca. CarmaCars';
  assert.equal(templateProblem(missed), null);
  assert.equal(segments(missed), 1);
  assert.match(templateProblem('Your booking \u2014 CarmaCars')!, /long dashes/);
  assert.match(templateProblem('Hello there')!, /CarmaCars/);
  assert.match(templateProblem('CarmaCars {colour}')!, /Unknown placeholder/);
  assert.match(templateProblem('CarmaCars ' + 'x'.repeat(480))!, /480/);
  assert.equal(renderTemplate('Hi {first_name}, your CarmaCars offer {booking} for the {car} is ready. Review and pay: {link}', SAMPLE_VARS),
    'Hi Maya, your CarmaCars offer CC-10482 for the 2024 Honda Civic Sport is ready. Review and pay: https://carmacars.ca/account/bookings/CC-10482');
  assert.equal(renderTemplate('Hi {first_name}, payment of {amount} received. CarmaCars', { first_name: 'Ali' }), 'Hi Ali, payment of received. CarmaCars');
  assert.equal(renderTemplate('Hi {first_name}, thanks. CarmaCars', {}), 'Hi, thanks. CarmaCars');
});

test('API client: sending a text (the key as it is, from our number, one recipient) and its errors', async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const ok: typeof fetch = async (url, init) => { calls.push({ url: String(url), init: init! }); return new Response(JSON.stringify({ data: { id: 'AC1', status: 'sent', conversationId: 'CN1' } }), { status: 202 }); };
  const r = await sendText({ key: 'k-123', fetch: ok }, { from: '+12893125991', to: THEM, content: ' Hi CarmaCars ' });
  assert.deepEqual(r, { id: 'AC1', status: 'sent', conversationId: 'CN1' });
  assert.equal(calls[0]!.url, 'https://api.openphone.com/v1/messages');
  assert.equal((calls[0]!.init.headers as Record<string, string>).authorization, 'k-123');
  assert.deepEqual(JSON.parse(String(calls[0]!.init.body)), { content: 'Hi CarmaCars', from: '+12893125991', to: [THEM] });
  const bad: typeof fetch = async () => new Response(JSON.stringify({ message: 'A2P Registration Not Approved', code: '0206400', status: 400 }), { status: 400 });
  await assert.rejects(sendText({ key: 'k', fetch: bad }, { from: OUR, to: THEM, content: 'x' }), (e: QuoError) => e.permanent && /A2P/.test(e.message));
  const busy: typeof fetch = async () => new Response('{}', { status: 429 });
  await assert.rejects(sendText({ key: 'k', fetch: busy }, { from: OUR, to: THEM, content: 'x' }), (e: QuoError) => !e.permanent);
  const nums: typeof fetch = async () => new Response(JSON.stringify({ data: [{ id: 'PNlohw5LLP', number: '+12893125991', name: 'Primary', users: [] }] }));
  assert.deepEqual(await listNumbers({ key: 'k', fetch: nums }), [{ id: 'PNlohw5LLP', number: '+12893125991', name: 'Primary' }]);
});

test('API client: the webhook is set up once (created, then kept; a missing key is rotated, never a second webhook)', async () => {
  const hooks: Array<{ id: string; url: string; events: string[]; resourceIds: string[]; status: string; label: string | null }> = [];
  const seen: string[] = [];
  const f: typeof fetch = async (url, init) => {
    const u = new URL(String(url)); const m = init?.method ?? 'GET';
    seen.push(`${m} ${u.pathname} ${(init?.headers as Record<string, string>)['quo-api-version'] ?? ''}`);
    if (m === 'GET') return new Response(JSON.stringify({ data: hooks }));
    if (m === 'POST' && u.pathname === '/webhooks') { const b = JSON.parse(String(init!.body)); const w = { id: '1', ...b }; hooks.push(w); return new Response(JSON.stringify({ data: { ...w, key: 'whsec_new' } }), { status: 201 }); }
    if (m === 'POST' && u.pathname.endsWith('/rotate')) return new Response(JSON.stringify({ data: { key: 'whsec_rotated' } }));
    if (m === 'PATCH') { Object.assign(hooks[0]!, JSON.parse(String(init!.body))); return new Response(JSON.stringify({ data: hooks[0] })); }
    return new Response('{}', { status: 404 });
  };
  const p = { url: 'https://carmacars.ca/api/webhooks/quo', events: EVENTS, resourceIds: ['PNlohw5LLP'], label: 'CarmaCars platform' };
  assert.deepEqual(await ensureWebhook({ key: 'k', fetch: f }, { ...p, haveKey: false }), { id: '1', action: 'created', key: 'whsec_new' });
  assert.deepEqual(await ensureWebhook({ key: 'k', fetch: f }, { ...p, haveKey: true }), { id: '1', action: 'kept', key: null });
  assert.deepEqual(await ensureWebhook({ key: 'k', fetch: f }, { ...p, events: ['call.missed'], haveKey: true }), { id: '1', action: 'updated', key: null });
  assert.deepEqual(await ensureWebhook({ key: 'k', fetch: f }, { ...p, haveKey: false }), { id: '1', action: 'rotated', key: 'whsec_rotated' });
  assert.equal(hooks.length, 1);
  assert.ok(seen.every((s) => s.endsWith('2026-03-30')));
});
