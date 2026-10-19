import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { amountsIn, centsIn, checkReply, escalationFor, percentsIn, tidy } from './guardrails.ts';
import { runAgent, replyContext, type AgentDeps, type ChatFacts, type Step } from './agent.ts';

// Live chat (migration 0060): the assistant's guardrails. The rule the owner set: no invented prices. Every amount
// the visitor reads must come from the database (a quote or a search through the pricing functions, or the fleet's
// rates and fees); anything else is refused and replaced by the quote's own words or a hand-over to a person.

const FACTS: ChatFacts = {
  today: '2026-10-19', weekday: 'Monday',
  site: { brand: 'CarmaCars', city: 'Toronto', phone: '+16475753377', hours: 'Open 24 hours', reply: 'within 2 hours' },
  rules: { min_age: 18, standard_min_age: 21, non_refundable_discount_bps: 1000, hst_bps: 1300,
    cancellation: { grace_bps: 9500, early_bps: 7500, mid_bps: 5000, late_bps: 0, grace_hours: 24, early_hours: 48, late_hours: 24 },
    fees: { cleaning: { label: 'Cleaning', unit: 'flat', amount_cents: 7500 } } },
  fleet: [{ slug: 'toyota-corolla', name: '2023 Toyota Corolla LE', class: 'economy', seats: 5, transmission: 'Automatic', fuel: 'gasoline', daily_rate_cents: 5900, deposit_cents: 50000, vehicle_id: 'v-corolla' },
          { slug: 'tesla-model-3', name: '2023 Tesla Model 3', class: 'premium', seats: 5, transmission: 'Automatic', fuel: 'electric', daily_rate_cents: 9900, deposit_cents: 100000, vehicle_id: 'v-tesla' }],
  never_say: ['Acme Mutual']
};
const QUOTE = { available: true, billable_days: 2, lines: [{ label: 'Rental charge', amount_cents: 11800 }], hst_cents: 1534, total_cents: 13334, deposit_cents: 50000, km_allowance_total: 800 };

function deps(steps: Step[], calls: string[] = []): AgentDeps {
  let i = 0;
  return {
    facts: FACTS,
    model: async (_s, prompt) => { calls.push(prompt); const data = steps[Math.min(i++, steps.length - 1)]!; return { ok: true, data, usage: { inputTokens: 1000, outputTokens: 100, neurons: 50 }, model: 'stub' }; },
    quote: async (vehicle) => { calls.push(`QUOTE ${vehicle}`); return QUOTE; },
    search: async () => [{ slug: 'toyota-corolla', make: 'Toyota', model: 'Corolla', vehicle_year: 2023, seats: 5, vehicle_class: 'economy', billable_days: 2, total_cents: 13334, deposit_cents: 50000, daily_rate_cents: 5900 }],
    lead: async (a) => (a.phone ? { ok: true, reference: 'LC-1001' } : { ok: false, missing: 'phone' }),
    instant: (d, t) => `${d}T${t}:00-04:00`
  };
}

describe('amounts and percentages in a text', () => {
  it('reads dollars in every common form', () => {
    assert.deepEqual(amountsIn('Total $1,334.50, Deposit $500, CA$ 59.00 a day, or 75 dollars'), [133450, 50000, 5900, 7500]);
    assert.deepEqual(percentsIn('10% off, 13 percent HST'), [10, 13]);
  });
  it('collects every _cents value of a tool result', () => {
    assert.deepEqual([...centsIn(QUOTE)].sort((a, b) => a - b), [1534, 11800, 13334, 50000]);
  });
});

describe('checkReply', () => {
  const ctx = replyContext(FACTS, [QUOTE], []);
  it('passes amounts the quote gave and the fleet rates', () => {
    assert.equal(checkReply('The total is $133.34 with HST and the Deposit is $500.00. From $59.00 a day.', ctx).ok, true);
  });
  it('refuses an invented price', () => {
    const r = checkReply('It would be about $120.00 for the weekend.', ctx);
    assert.equal(r.ok, false);
    assert.match((r as { reason: string }).reason, /amount the database did not give/);
  });
  it('refuses an invented price even without a quote in the conversation', () => {
    assert.equal(checkReply('The Tesla is $89.00 a day.', replyContext(FACTS, [], [])).ok, false);
  });
  it('allows an amount quoted earlier in the conversation (kept in the reply meta)', () => {
    assert.equal(checkReply('Yes, still $133.34 in total.', replyContext(FACTS, [], [{ sender: 'ai', body: 'x', meta: { cents: [13334] } }])).ok, true);
  });
  it('refuses discounts beyond the non-refundable one, promises, insurance words, provider names and legal advice', () => {
    assert.equal(checkReply('I can give you 15% off today.', ctx).ok, false);
    assert.equal(checkReply('I can apply a discount for you.', ctx).ok, false);
    assert.equal(checkReply('A non-refundable booking is 10% cheaper.', ctx).ok, true);
    assert.equal(checkReply('Great, the car is reserved for you.', ctx).ok, false);
    assert.equal(checkReply('Your insurance covers it.', ctx).ok, false);
    assert.equal(checkReply('The Protection Plan includes coverage for damage.', ctx).ok, false);
    assert.equal(checkReply('The plan is from Acme Mutual.', ctx).ok, false);
    assert.equal(checkReply('You are not liable for that.', ctx).ok, false);
  });
  it('tidies the house style', () => {
    assert.equal(tidy('Hi — welcome to carmacars'), 'Hi, welcome to CarmaCars');
  });
});

describe('escalation before the model', () => {
  it('sends complaints, damage, payments, insurance and a request for a person to staff', () => {
    assert.equal(escalationFor('Can I talk to a person?'), 'person');
    assert.equal(escalationFor('I had an accident on the 401'), 'damage');
    assert.equal(escalationFor('I was charged twice'), 'payment');
    assert.equal(escalationFor('This is a scam'), 'complaint');
    assert.equal(escalationFor('Does it include insurance?'), 'insurance');
    assert.equal(escalationFor('Is the Corolla free this weekend?'), null);
  });
});

describe('runAgent', () => {
  it('hands over without calling the model when the visitor asks for a person', async () => {
    const calls: string[] = [];
    const r = await runAgent(deps([{ action: 'reply', reply: 'x' }], calls), { history: [], text: 'I want to speak to a person' });
    assert.equal(r.handoff?.escalation, 'person');
    assert.equal(calls.length, 0);
    assert.equal(r.neurons, 0);
  });
  it('quotes through the pricing function and lets the reply repeat its amounts', async () => {
    const calls: string[] = [];
    const r = await runAgent(deps([{ action: 'quote', car: 'toyota-corolla', pickup_date: '2026-11-02', return_date: '2026-11-04' },
      { action: 'reply', reply: 'The Corolla is free: $133.34 in total with HST, Deposit $500.00.' }], calls), { history: [], text: 'Corolla Nov 2 to 4?' });
    assert.equal(r.reply, 'The Corolla is free: $133.34 in total with HST, Deposit $500.00.');
    assert.ok(calls.includes('QUOTE v-corolla'), 'the quote came from the pricing function');
    assert.match(calls.find((c) => c.includes('TOOL RESULTS'))!, /Total \$133\.34/);
    assert.equal(r.meta.quote_total_cents, 13334);
    assert.deepEqual(r.meta.cents?.sort((a, b) => a - b), [1534, 11800, 13334, 50000]);
    assert.equal(r.neurons, 100);
  });
  it('replaces a reply with an invented price by the quote\'s own words', async () => {
    const r = await runAgent(deps([{ action: 'quote', car: 'toyota-corolla', pickup_date: '2026-11-02', return_date: '2026-11-04' },
      { action: 'reply', reply: 'That will be $97.00, a great price!' }]), { history: [], text: 'How much?' });
    assert.match(r.reply!, /\$133\.34 in total with HST, Deposit \$500\.00/);
    assert.deepEqual(r.meta.refused, ['an amount the database did not give: 97.00']);
  });
  it('hands over when a price is invented and there is no quote to fall back on', async () => {
    const r = await runAgent(deps([{ action: 'reply', reply: 'The Tesla is $70.00 a day for you.' }]), { history: [], text: 'Price of the Tesla?' });
    assert.equal(r.reply, undefined);
    assert.match(r.handoff!.reason, /could not answer safely/);
  });
  it('asks for what is missing before starting a request, then creates it', async () => {
    const r1 = await runAgent(deps([{ action: 'start_request', name: 'Maya Chen', email: 'maya@example.test', car: 'toyota-corolla' },
      { action: 'reply', reply: 'What phone number can we reach you at?' }]), { history: [], text: 'Book it' });
    assert.equal(r1.reply, 'What phone number can we reach you at?');
    const r2 = await runAgent(deps([{ action: 'start_request', name: 'Maya Chen', email: 'maya@example.test', phone: '4165550142', car: 'toyota-corolla' }]), { history: [], text: '416 555 0142' });
    assert.match(r2.reply!, /reference LC-1001/);
    assert.match(r2.reply!, /Nothing is booked until you approve the offer, sign and pay/);
  });
  it('a model failure becomes a hand-over ("A person will reply shortly")', async () => {
    const d = deps([]);
    d.model = async () => ({ ok: false, reason: 'quota', message: '4006 daily allocation' });
    const r = await runAgent(d, { history: [], text: 'Hello' });
    assert.equal(r.ok, false);
    assert.equal(r.handoff?.reason, 'the assistant is not available');
  });
});
