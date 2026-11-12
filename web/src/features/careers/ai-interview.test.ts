import { test } from 'node:test';
import assert from 'node:assert/strict';
import { audioExt, fakeFollowup, fakeScores, followupPrompt, pickFollowup, PLAIN_FOLLOWUP, scorePrompt, scoreSystem, TEST_WORDS, transcribeNeurons, words } from './ai-interview.ts';
import { fakeTranscriber, FAKE_SENTENCE } from '../../integrations/transcribe/fake.ts';
import { base64, workersAiTranscriber } from '../../integrations/transcribe/workers-ai.ts';
import { guardTranscriber, tierOf, TASK_PURPOSE } from '../../integrations/ai/guard.ts';

// The AI interview (migration 0380): the follow-up rule, the prompts, the recordings kept, the speech to text behind the
// usage guard, and the fake providers the end-to-end tests use.
const topics = [{ key: 'internet', label: 'Internet and backup', weight: 10, good: 'fiber' }, { key: 'experience', label: 'Experience', weight: 20, good: 'a year' },
  { key: 'canada', label: 'Moving to Canada', weight: 0, good: 'noted' }];

test('follow-ups: a long answer never gets one; a vague one gets the model\'s question, or the plain one without the model', () => {
  const long = 'word '.repeat(170);
  assert.equal(pickFollowup(long, { vague: true, followup: 'Which tools?' }), '', 'a detailed answer is never followed up');
  assert.equal(pickFollowup('I did support.', { vague: true, followup: 'Which tools did you use, and for how many customers a day?' }), 'Which tools did you use, and for how many customers a day?');
  assert.equal(pickFollowup('I did support for a US company for two years with many tickets every day of the week.', { vague: false, followup: '' }), '');
  assert.equal(pickFollowup('Yes.', null), PLAIN_FOLLOWUP, 'the model cannot be asked: a very short answer still gets the plain follow-up');
  assert.equal(pickFollowup('I worked in customer support at a call centre in Manila for two years answering calls.', null), '', 'without the model, only a very short answer');
  assert.equal(pickFollowup('Yes.', { vague: true, followup: 'For this test, which tools?' }), PLAIN_FOLLOWUP, 'never a test: the plain one instead');
  assert.equal(pickFollowup('Some.', { vague: true, followup: 'Tell me more' }), PLAIN_FOLLOWUP, 'not a question: the plain one');
  assert.ok(!TEST_WORDS.test(PLAIN_FOLLOWUP));
});

test('the prompts: the answer is quoted for the follow-up; the scores see every answer, the topics and the Sales rule', () => {
  assert.match(followupPrompt('What did you do?', 'Support.'), /<question>\nWhat did you do\?\n<\/question>\n<answer>\nSupport\.\n<\/answer>/);
  const sys = scoreSystem(topics, false);
  assert.match(sys, /^- internet: Internet and backup; fiber$/m);
  assert.match(sys, /"sales" \(does not pass for this role but could sell/);
  assert.match(scoreSystem(topics, true), /never "sales" for this Sales role/);
  assert.doesNotMatch(sys, /—|–/, 'no long dashes');
  const p = scorePrompt({ role_title: 'Customer Service', va_function: 'cs', hours: '6 days.', pay_text: 'US$400 a month', answers: [
    { seq: 1, kind: 'question', key: 'experience', prompt: 'Your last job?', mode: 'voice', transcript: 'Two years of chat support.' },
    { seq: 2, kind: 'followup', key: 'experience', prompt: 'Which tools?', mode: 'typed', transcript: 'Zendesk.' }] });
  assert.match(p, /Q1 \[experience\]: Your last job\?\nA1 \(spoken\): Two years of chat support\./);
  assert.match(p, /Q2 \(follow-up\) \[experience\]: Which tools\?\nA2 \(typed\): Zendesk\./);
});

test('the fake model: a follow-up below 25 words; scores with quotes taken from the answers', () => {
  assert.equal(fakeFollowup(followupPrompt('Q', 'Short answer.')).vague, true);
  assert.equal(fakeFollowup(followupPrompt('Q', 'word '.repeat(30))).vague, false);
  const p = scorePrompt({ role_title: 'R', va_function: 'cs', hours: null, pay_text: 'US$400', answers: [
    { seq: 1, kind: 'question', key: 'experience', prompt: 'Q', mode: 'voice', transcript: 'I answered sixty chats a day for an internet provider in Texas for two full years' },
    { seq: 2, kind: 'question', key: 'internet', prompt: 'Q', mode: 'typed', transcript: 'Fiber 100 Mbps' }] });
  const s = fakeScores(p, topics) as { topics: Array<{ key: string; score: number; evidence: string }>; recommendation: string };
  assert.deepEqual(s.topics.map((t) => [t.key, t.score]), [['internet', 2], ['experience', 3], ['canada', 1]]);
  assert.equal(s.topics[1]!.evidence, 'I answered sixty chats a day for an');
  assert.ok(p.includes(s.topics[1]!.evidence));
});

test('recordings: the browser types kept, with their file extension; anything else refused', () => {
  assert.equal(audioExt('audio/webm;codecs=opus'), 'webm');
  assert.equal(audioExt('audio/mp4'), 'm4a');
  assert.equal(audioExt('audio/ogg; codecs=opus'), 'ogg');
  assert.equal(audioExt('video/webm'), 'webm');
  assert.equal(audioExt('application/pdf'), null);
  assert.equal(audioExt(''), null);
  assert.equal(words('  two   words '), 2);
  assert.equal(transcribeNeurons(60), 47);
  assert.equal(transcribeNeurons(0), 1);
});

test('speech to text: the fake hears the marker of the end-to-end tests, or one plain sentence', async () => {
  const enc = new TextEncoder();
  const heard = await fakeTranscriber().transcribe({ audio: enc.encode('RIFF....FAKE-TRANSCRIPT:I have two years of chat support.'), type: 'audio/webm', seconds: 4 });
  assert.deepEqual(heard, { ok: true, text: 'I have two years of chat support.', model: 'fake-whisper-v1', neurons: 0 });
  const plain = await fakeTranscriber().transcribe({ audio: new Uint8Array([1, 2, 3]), type: 'audio/webm', seconds: 4 });
  assert.equal(plain.ok && plain.text, FAKE_SENTENCE);
});

test('Workers AI Whisper: turbo gets base64 English audio; the neurons by the minute; a quota error is "quota"', async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const ai = { async run(model: string, input: Record<string, unknown>) { calls.push([model, input]); return { text: '  Hello   there ' }; } };
  const r = await workersAiTranscriber(ai).transcribe({ audio: new Uint8Array([104, 105]), type: 'audio/webm', seconds: 90 });
  assert.deepEqual(r, { ok: true, text: 'Hello there', model: '@cf/openai/whisper-large-v3-turbo', neurons: 70 });
  assert.deepEqual(calls[0], ['@cf/openai/whisper-large-v3-turbo', { audio: 'aGk=', language: 'en', vad_filter: true }]);
  await workersAiTranscriber(ai).transcribe({ audio: new Uint8Array([1, 2]), type: 'audio/webm', seconds: 10, model: '@cf/openai/whisper' });
  assert.deepEqual(calls[1], ['@cf/openai/whisper', { audio: [1, 2] }]);
  const busy = { async run() { throw new Error('4006: you have used up your daily free allocation of 10,000 neurons'); } };
  const q = await workersAiTranscriber(busy).transcribe({ audio: new Uint8Array([1]), type: 'audio/webm', seconds: 5 });
  assert.equal(!q.ok && q.reason, 'quota');
  assert.equal(base64(new Uint8Array(70000).fill(65)).length, Math.ceil(70000 / 3) * 4, 'large recordings encode in chunks');
});

test('the usage guard: transcripts and follow-ups are live work, the scores background; a transcript that does not fit is not made', async () => {
  assert.equal(tierOf('interview_transcribe'), 'live');
  assert.equal(tierOf('interview_followup'), 'live');
  assert.equal(tierOf('interview_score'), 'background');
  assert.equal(TASK_PURPOSE.interview_score, 'interview_score');
  let called = 0;
  const inner = { name: 'fake' as const, async transcribe() { called++; return { ok: true as const, text: 'x', model: 'm', neurons: 5 }; } };
  const spent: Array<[string, number]> = [];
  const asks: Array<{ purpose: string; estimate: number } | undefined> = [];
  const full = guardTranscriber(inner, async (ask) => { asks.push(ask); return true; });
  const r = await full.transcribe({ audio: new Uint8Array([1]), type: 'audio/webm', seconds: 120 });
  assert.equal(!r.ok && r.reason, 'quota');
  assert.equal(called, 0);
  assert.deepEqual(asks[0], { purpose: 'interview_transcribe', estimate: 94 });
  const open = guardTranscriber(inner, async () => false, (p, n) => spent.push([p, n]));
  assert.equal((await open.transcribe({ audio: new Uint8Array([1]), type: 'audio/webm', seconds: 10 })).ok, true);
  assert.deepEqual(spent, [['interview_transcribe', 5]]);
});

// ---------------------------------------------------------------- release 30 (0585): the answer on video
test('video: the types kept, the type each recording is served with, the clock, why a browser cannot record', async () => {
  const m = await import('./ai-interview.ts');
  assert.equal(m.videoExt('video/webm;codecs=vp8,opus'), 'webm');
  assert.equal(m.videoExt('video/mp4;codecs=avc1,mp4a'), 'mp4');
  assert.equal(m.videoExt('audio/webm'), null);
  assert.equal(m.recordingMime('hiring/interviews/x/1-abc-v.webm'), 'video/webm');
  assert.equal(m.recordingMime('hiring/interviews/x/1-abc-v.mp4'), 'video/mp4');
  assert.equal(m.recordingMime('hiring/interviews/x/1-abc.m4a'), 'audio/mp4');
  assert.equal(m.clock(120), '2:00');
  assert.equal(m.clock(14.2), '0:15');
  assert.equal(m.clock(-3), '0:00');
  assert.equal(m.DEFAULT_ANSWER_SECONDS, 120);
  assert.match(m.cannotRecordWhy({ name: 'NotAllowedError' }, true), /blocked/);
  assert.match(m.cannotRecordWhy({ name: 'NotFoundError' }, true), /could not find a camera/);
  assert.match(m.cannotRecordWhy(null, false), /cannot record video/);
  for (const n of ['NotAllowedError', 'NotFoundError', 'NotReadableError', 'Other']) assert.doesNotMatch(m.cannotRecordWhy({ name: n }, true), /[—–]|Error|getUserMedia/);
  // the scoring reads an answer the time ran out on as no answer
  assert.match(m.scorePrompt({ role_title: 'R', va_function: 'cs', hours: null, pay_text: 'P', answers: [{ seq: 1, kind: 'question', key: 'k', prompt: 'Q?', mode: 'none', transcript: 'No answer: the time ran out.' }] }), /A1 \(no answer\)/);
});
