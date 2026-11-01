import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { CONTACT_ASK, faqReply, focusFleet, factsText, runAgent, withContactAsk, type AgentDeps, type ChatFacts, type FleetCar } from './agent.ts';
import { escalationFor } from './guardrails.ts';
import { handoffFor, notAnsweredFor, QUOTA_REASON } from './reply-path.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import { jsonIn, workersAi, CHAT_MODEL, DRAFT_MODEL, type AiBinding } from '../../integrations/llm/workers-ai.ts';

// Live chat (migration 0370): the assistant's reply path with the fake AI provider (the stand-in the local site and the
// e2e run use), the answers from the facts with no model call, the shorter context, the contact question, and what
// staff read when the assistant does not answer.

const car = (slug: string, name: string, cls: string, daily: number): FleetCar => ({ slug, name, class: cls, seats: 5, transmission: 'Automatic', fuel: 'gasoline', daily_rate_cents: daily, deposit_cents: 50000, vehicle_id: `v-${slug}` });
const FLEET = [car('toyota-corolla', '2023 Toyota Corolla LE', 'economy', 5900), car('tesla-model-3', '2023 Tesla Model 3', 'premium', 9900),
  ...Array.from({ length: 30 }, (_, i) => car(`kia-k${i}`, `2024 Kia K${i}`, i % 2 ? 'suv' : 'standard', 6000 + i * 100))];
const FACTS: ChatFacts = {
  today: '2026-11-01', weekday: 'Sunday',
  site: { brand: 'CarmaCars', city: 'Toronto', phone: '+12893125991', hours: 'Open 24 hours', reply: 'within 2 hours' },
  rules: { min_age: 18, standard_min_age: 21, licences: ['G'], deposit_release_days: 7, offer_hours: 24, non_refundable_discount_bps: 1000, hst_bps: 1300,
    cancellation: { grace_bps: 9500, early_bps: 7500, mid_bps: 5000, late_bps: 0, grace_hours: 24, early_hours: 48, late_hours: 24 } },
  fleet: FLEET, never_say: []
};
const QUOTE = { available: true, billable_days: 2, lines: [{ label: 'Rental charge', amount_cents: 11800 }], hst_cents: 1534, total_cents: 13334, deposit_cents: 50000, km_allowance_total: 800 };

/** The agent with the fake provider, as /api/chat runs it without the Worker's AI binding. */
function fakeDeps(prompts: string[] = []): AgentDeps {
  const gen = fakeText();
  return {
    facts: FACTS,
    model: async (system, prompt) => {
      prompts.push(prompt);
      const r = await gen.generate<never>({ task: 'chat', system, prompt, schema: {}, maxOutputTokens: 300 });
      return r.ok ? { ok: true, data: r.data, usage: r.usage, model: r.model } : { ok: false, reason: r.reason, message: r.message, usage: r.usage };
    },
    quote: async () => QUOTE,
    search: async () => [],
    lead: async () => ({ ok: true, reference: 'LC-1001' }),
    instant: (d, t) => `${d}T${t}:00-04:00`
  };
}

describe('the reply path with the fake AI provider', () => {
  it('answers a price question from the pricing function, asks for a phone or email, and costs no stand-in neurons', async () => {
    const prompts: string[] = [];
    const r = await runAgent(fakeDeps(prompts), { history: [], text: 'How much is the Toyota Corolla from 2026-11-02 to 2026-11-04?', car: null });
    assert.equal(r.ok, true);
    assert.match(r.reply!, /\$133\.34 in total with HST, Deposit \$500\.00/);
    assert.ok(r.reply!.endsWith(CONTACT_ASK));
    assert.deepEqual(r.meta.tools.map((t) => t.name), ['quote']);
    assert.equal(prompts.length, 2, 'a quote step, then the reply');
  });
  it('does not ask again once the visitor gave a phone or email, or after its first answer', async () => {
    const a = await runAgent(fakeDeps(), { history: [], text: 'hello', email: 'maya@example.test' });
    assert.ok(!a.reply!.includes(CONTACT_ASK));
    const b = await runAgent(fakeDeps(), { history: [{ sender: 'visitor', body: 'hi' }, { sender: 'ai', body: 'Hello!' }], text: 'and the Tesla?' });
    assert.ok(!b.reply!.includes(CONTACT_ASK));
  });
  it('a greeting does not count as its first answer', () => {
    assert.ok(withContactAsk('Sure.', { history: [{ sender: 'ai', body: 'Hi!', meta: { greeting: true } }] }).endsWith(CONTACT_ASK));
  });
  it('a failing provider is a hand-over with a note for staff, never a silent one', async () => {
    process.env.FAKE_LLM_FAIL = '1';
    try {
      const r = await runAgent(fakeDeps(), { history: [], text: 'Which car fits 7 people?' });
      assert.equal(r.ok, false);
      assert.equal(r.reply, undefined);
      const h = handoffFor(r);
      assert.equal(h.quota, false);
      assert.match(h.note!, /^The assistant could not reply \(unavailable: The fake model is set to fail\)/);
    } finally { delete process.env.FAKE_LLM_FAIL; }
  });
  it('the day\'s allowance: the visitor reads that the assistant rests, staff read why', () => {
    const h = handoffFor({ ok: false, error: 'quota: share used', handoff: { reason: 'x' } });
    assert.deepEqual([h.reason, h.quota], [QUOTA_REASON, true]);
    assert.match(h.note!, /^AI replies paused: /);
    assert.equal(handoffFor({ ok: true, handoff: { reason: 'asked for a person' } }).note, null);
  });
  it('a message the database kept from the assistant says why to staff', () => {
    assert.match(notAnsweredFor({ ai_reason: 'budget', reason: 'the AI assistant is turned off (Settings > Program)' })!.note, /^AI replies paused: the AI assistant is turned off/);
    assert.equal(notAnsweredFor({ ai_reason: 'max_replies' })!.budget, false);
    assert.equal(notAnsweredFor({ ai_reason: 'person' }), null);
  });
});

describe('answers from the facts (no model call)', () => {
  it('answers the deposit, age, booking, cancellation, hours and delivery questions from the facts', () => {
    assert.equal(faqReply(FACTS, 'How does the deposit work?')!.topic, 'deposit');
    assert.match(faqReply(FACTS, 'how old do I need to be')!.reply, /21 or older/);
    assert.equal(faqReply(FACTS, 'How do I book?')!.topic, 'booking');
    assert.match(faqReply(FACTS, 'what is your cancellation policy')!.reply, /75%/);
    assert.equal(faqReply(FACTS, 'what are your hours?')!.topic, 'hours');
  });
  it('leaves dates, a named car or two topics to the model', () => {
    assert.equal(faqReply(FACTS, 'Deposit for the Corolla?'), null);
    assert.equal(faqReply(FACTS, 'deposit for 2026-11-02 to 2026-11-04'), null);
    assert.equal(faqReply(FACTS, 'deposit and cancellation?'), null);
  });
  it('runs with no neurons and no model call', async () => {
    const prompts: string[] = [];
    const r = await runAgent(fakeDeps(prompts), { history: [], text: 'How does the deposit work?' });
    assert.equal(prompts.length, 0);
    assert.equal(r.neurons, 0);
    assert.equal(r.model, 'faq');
    assert.match(r.reply!, /hold on your credit card/);
  });
});

describe('a shorter context', () => {
  it('lists the page\'s car and the cars named first, at most 12, and says how many there are', () => {
    const f = focusFleet(FACTS, { car: 'kia-k17', text: 'is the tesla model 3 free?' });
    assert.equal(f.length, 12);
    assert.deepEqual(f.slice(0, 2).map((c) => c.slug), ['kia-k17', 'tesla-model-3']);
    const txt = factsText(FACTS, { car: 'kia-k17', text: '' });
    assert.match(txt, /These are 12 of our 32 cars \(from \$59\.00 a day\)/);
    const carLines = (t: string) => t.split('\n').filter((l) => / \| from \$/.test(l)).length;
    assert.deepEqual([carLines(txt), carLines(factsText(FACTS))], [12, 32]);
  });
});

describe('escalation words (0370)', () => {
  it('a question about a person under 25 or the legal age stays with the assistant', () => {
    assert.equal(escalationFor('Can a person under 25 rent the Tesla?'), null);
    assert.equal(escalationFor('What is the legal age to rent?'), null);
    assert.equal(escalationFor('Can I chat with a human please'), 'person');
    assert.equal(escalationFor('I need legal advice about a ticket'), 'legal');
  });
});

describe('the small model without JSON mode', () => {
  it('reads the JSON object from the text', () => {
    assert.deepEqual(jsonIn('Sure! {"action": "reply", "reply": "Hi {there}"} Thanks'), { action: 'reply', reply: 'Hi {there}' });
    assert.equal(jsonIn('no json here'), undefined);
  });
  it('asks the 70B model (JSON mode) once when the small one wrote no object, and counts both', async () => {
    const asked: Array<{ model: string; json: boolean }> = [];
    const ai: AiBinding = { run: async (model, input) => {
      asked.push({ model, json: 'response_format' in input });
      return model === CHAT_MODEL ? { response: 'I think you should book it', usage: { prompt_tokens: 1000, completion_tokens: 20 } }
        : { response: { action: 'reply', reply: 'Hello' }, usage: { prompt_tokens: 1000, completion_tokens: 20 } };
    } };
    const r = await workersAi(ai, CHAT_MODEL, 5000).generate<{ action: string }>({ task: 'chat', system: 's', prompt: 'p', schema: {}, maxOutputTokens: 100 });
    assert.deepEqual(asked, [{ model: CHAT_MODEL, json: false }, { model: DRAFT_MODEL, json: true }]);
    assert.equal(r.ok && r.data.action, 'reply');
    assert.equal(r.usage!.neurons, 5 + 31, 'the small model\'s 5 neurons and the 70B\'s 31');
  });
});
