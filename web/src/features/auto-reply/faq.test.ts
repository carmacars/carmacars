import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AI_LABEL, closest, isQuestion, readAnswer, replyMime, robotEmail, systemPrompt, userPrompt, words, type FaqEntry } from './faq.ts';

const FAQ: FaqEntry[] = [
  { key: 'f1', q: 'How old do I have to be to rent?', a: 'You must be 21 or older. Drivers aged 18 to 20 can rent selected cars.' },
  { key: 'f2', q: 'Is there a security deposit?', a: 'Yes, a refundable deposit is held on your card and released after the trip.' },
  { key: 'f3', q: 'Do you deliver the car?', a: 'Yes, we deliver across the GTA and to Pearson airport for a fee.' }
];

test('the closest entries share the question\'s words; nothing for small talk', () => {
  assert.equal(closest('How old must I be to rent a car?', FAQ)[0]!.key, 'f1');
  assert.equal(closest('Can you deliver to the airport?', FAQ)[0]!.key, 'f3');
  assert.deepEqual(closest('thanks!', FAQ), []);
  assert.deepEqual(words('Deposits, please'), ['deposit']);
});

test('the prompt: only the FAQ, the rules, the length of the channel', () => {
  assert.match(systemPrompt('CarmaCars'), /ONLY the FAQ entries given/);
  assert.match(systemPrompt('CarmaCars'), /booking, a payment, a complaint/);
  assert.match(userPrompt('deposit?', FAQ.slice(1, 2), 'sms'), /\[f2\] Q: Is there a security deposit\?[\s\S]*at most 300 characters/);
});

test('the answer is checked: unknown keys dropped, no key means not sure, long answers cut for a text', () => {
  const ok = readAnswer({ faq: ['f2', 'zz'], answer: 'Hi! Yes — a refundable deposit is held on your card.', confident: true, confidence: 0.9 }, FAQ, 'email');
  assert.deepEqual(ok, { faq: ['f2'], answer: `${AI_LABEL.other.before}Yes, a refundable deposit is held on your card.${AI_LABEL.other.after}`, confident: true, confidence: 0.9 });
  assert.equal(readAnswer({ faq: ['zz'], answer: 'Made up.', confident: true, confidence: 1 }, FAQ, 'sms').confident, false);
  assert.equal(readAnswer('not json', FAQ, 'sms').confident, false);
  const long = readAnswer({ faq: ['f1'], answer: 'word '.repeat(200), confident: true, confidence: 0.8 }, FAQ, 'sms');
  assert.ok(long.answer.length <= 320);
});

test('a question, not a keyword or a thank you', () => {
  assert.equal(isQuestion('STOP'), false);
  assert.equal(isQuestion('thanks'), false);
  assert.equal(isQuestion('do you deliver to pearson?'), true);
  // r40: only clear questions: a statement or a two-word note gets no automatic answer
  assert.equal(isQuestion('I am outside now'), false);
  assert.equal(isQuestion('deposit?'), false);
  const sms = readAnswer({ faq: ['f1'], answer: 'word '.repeat(200), confident: true, confidence: 0.95 }, FAQ, 'sms');
  assert.ok(sms.answer.startsWith(AI_LABEL.sms.before) && sms.answer.endsWith(AI_LABEL.sms.after) && sms.answer.length <= 320);
});

test('robots, lists, bounces and our own address never get an answer', () => {
  assert.equal(robotEmail({ 'auto-submitted': 'auto-replied' }, 'a@example.test'), true);
  assert.equal(robotEmail({ precedence: 'bulk' }, 'a@example.test'), true);
  assert.equal(robotEmail({ 'list-id': '<x>' }, 'a@example.test'), true);
  assert.equal(robotEmail({}, 'No Reply <noreply@example.test>'), true);
  assert.equal(robotEmail({}, 'info@carmacars.ca'), true);
  assert.equal(robotEmail({}, 'Ana <ana@example.test>'), false);
});

test('the reply email answers the message and says it is automatic', () => {
  const m = replyMime({ from: 'help@in.carmacars.ca', to: 'ana@example.test', subject: 'Deposit?', text: 'Yes.\nThanks', inReplyTo: '<abc@x>', id: 'r1@in.carmacars.ca', date: new Date('2026-11-11T12:00:00Z') });
  assert.match(m, /^From: help@in\.carmacars\.ca\r\nTo: ana@example\.test\r\nSubject: Re: Deposit\?/);
  assert.match(m, /In-Reply-To: <abc@x>\r\nReferences: <abc@x>/);
  assert.match(m, /Auto-Submitted: auto-replied/);
  assert.match(m, /\r\n\r\nYes\.\r\nThanks/);
  assert.match(replyMime({ from: 'a', to: 'b', subject: 'Dépôt', text: 'x', inReplyTo: null, id: 'i', date: new Date() }), /Subject: =\?UTF-8\?B\?/);
});
