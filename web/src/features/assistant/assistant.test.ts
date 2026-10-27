import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { checkArgs, jsonSchemas, shortDate, summary, toolsFor, TOOLS, type ToolName } from './tools.ts';
import { ask, systemPrompt, tidyArgs, type AssistantModel, type Deps, type Step } from './agent.ts';
import { fakeStep, claudeModel } from './models.ts';
import { beforeTax, hstOf } from '../sales/taxIncluded.ts';
import { PAUSE, pauseMessage, paidCost, capProblem, usedUpTitle } from '../usage/model.ts';

// The staff assistant and the usage guard (migration 0080): the tools each portal sees, argument checks, the card text
// of each change, the read-then-answer flow with one model call, the paused states and their words.

function stub(step: Step | ((text: string) => Step), service: 'workers_ai' | 'claude' = 'workers_ai'): AssistantModel & { calls: number; prompts: string[] } {
  const m = {
    name: 'fake' as const, service, calls: 0, prompts: [] as string[],
    async step(system: string, turns: Array<{ role: string; text: string }>) {
      m.calls++; m.prompts.push(system);
      const last = turns[turns.length - 1]!.text;
      return { ok: true as const, step: typeof step === 'function' ? step(last) : step, usage: { units: 12, unit: 'neurons' as const }, model: 'stub' };
    }
  };
  return m;
}
const ROWS: Record<string, Array<Record<string, unknown>>> = {
  invoice: [{ id: 'i1', invoice_number: 'INV-1053', owner: 'Karan Vakil', status: 'issued', balance_cents: 90000, total_cents: 90000 }],
  car: [{ id: 'v1', name: '2023 Toyota Corolla LE', plate: 'CBXT123', status: 'available' }, { id: 'v2', name: '2022 Toyota Corolla SE', plate: 'CDEF456', status: 'available' }],
  booking: [{ id: 'b1', booking_number: 'R-000123', renter: 'Maya Chen', status: 'offered' }],
  toll: [{ id: 't1', notice_number: 'N12345', plate: 'CBXT123', booking_number: 'R-000123', matched_to: 'renter' }],
  car_now: [{ car: '2023 Tesla Model 3', plate: 'TES123', booking_number: 'R-000200', renter: 'Ali', due_back: '2026-10-25T14:00:00Z', car_status: 'on_rent' }],
  owner_balance: [{ owner_id: 'o1', owner: 'Karan Vakil', balance_cents: 90000, open_invoices: [{ invoice_number: 'INV-1053', balance_cents: 90000, status: 'issued' }] }]
};
function deps(model: AssistantModel, o: Partial<Deps> = {}) {
  const proposed: Array<Record<string, unknown>> = [];
  const recorded: Array<Record<string, unknown>> = [];
  const d: Deps = {
    who: { portal: 'admin' }, today: '2026-10-21', model,
    gate: async () => ({ ok: true }),
    record: async (u) => { recorded.push(u as unknown as Record<string, unknown>); },
    todo: async () => [{ type: 'results', title: '2 things need you', rows: [{ title: '2 · New requests', href: '/admin/requests' }] }],
    find: async (kind, q) => (ROWS[kind] ?? []).filter((r) => kind !== 'car' || JSON.stringify(r).toLowerCase().includes(q.toLowerCase().split(' ')[0]!)),
    available: async () => [{ vehicle_year: 2023, make: 'Toyota', model: 'Corolla', slug: 'toyota-corolla', total_cents: 13334, daily_rate_cents: 5900 }],
    propose: async (p) => { proposed.push(p as unknown as Record<string, unknown>); return { id: 'act-1', summary: p.summary }; },
    now: () => Date.parse('2026-10-21T15:00:00Z'),
    ...o
  };
  return { d, proposed, recorded };
}

describe('tools per portal', () => {
  it('an Admin sees every tool; field staff only the five of their work', () => {
    assert.equal(toolsFor({ portal: 'admin' }).length, Object.keys(TOOLS).length);
    assert.deepEqual(toolsFor({ portal: 'field' }), ['today', 'find', 'availability', 'who_has_car', 'add_rental']);
  });
  it('an assistant sees their function\'s tools: Finance records payments and tolls, Fleet sets rates and publishes', () => {
    const fin = toolsFor({ portal: 'va', fn: 'finance' }), fleet = toolsFor({ portal: 'va', fn: 'fleet' }), sales = toolsFor({ portal: 'va', fn: 'sales' });
    assert.ok(fin.includes('record_payment') && fin.includes('confirm_toll') && !fin.includes('set_rates'));
    assert.ok(fleet.includes('set_rates') && fleet.includes('publish_car') && !fleet.includes('record_payment'));
    assert.ok(!sales.includes('confirm_toll') && !sales.includes('owner_balance'));
  });
  it('the system prompt lists only the person\'s tools (small requests save neurons)', () => {
    const p = systemPrompt({ portal: 'field' }, '2026-10-21', toolsFor({ portal: 'field' }));
    assert.ok(p.includes('- who_has_car:') && !p.includes('- record_payment:') && !p.includes('- set_rates:'));
    assert.ok(p.length < 2000, `prompt ${p.length} characters`);
  });
  it('every tool has a JSON schema for native tool calling (Claude)', () => {
    const s = jsonSchemas(Object.keys(TOOLS) as ToolName[]);
    assert.equal(s.length, Object.keys(TOOLS).length);
    for (const x of s) assert.equal((x.input_schema as { type?: string }).type, 'object', x.name);
    assert.ok(JSON.stringify(s.find((x) => x.name === 'record_payment')).includes('e_transfer'));
  });
});

describe('argument checks', () => {
  it('a payment needs the invoice or the booking, a method, a date, and the reference of an e-Transfer', () => {
    assert.equal(checkArgs('record_payment', { invoice: 'INV-1053', method: 'e_transfer', received_on: '2026-10-15', amount: 900, reference: 'CA1234' }).ok, true);
    const r = checkArgs('record_payment', { invoice: 'INV-1053', method: 'e_transfer', received_on: '2026-10-15' });
    assert.equal(r.ok, false); assert.match((r as { problem: string }).problem, /reference/);
    const both = checkArgs('record_payment', { invoice: 'INV-1', booking: 'R-1', method: 'cash', received_on: '2026-10-15' });
    assert.match((both as { problem: string }).problem, /one of them/);
    assert.match((checkArgs('record_payment', { invoice: 'INV-1053', method: 'wire', received_on: '2026-10-15' }) as { problem: string }).problem, /method/);
  });
  it('dates and times have one format; unknown fields are refused', () => {
    assert.equal(checkArgs('availability', { pickup_date: 'Nov 2', return_date: '2026-11-04' }).ok, false);
    assert.match((checkArgs('publish_car', { car: 'Corolla', price: 5 }) as { problem: string }).problem, /remove price/);
    assert.equal(checkArgs('add_rental', { car: 'Corolla', pickup_at: '2026-10-22 10:00', return_at: '2026-10-25 10:00', renter_name: 'Maya Chen', renter_email: 'maya@example.test', renter_mobile: '4165550100' }).ok, true);
  });
  it('amounts typed as text become numbers', () => {
    assert.deepEqual(tidyArgs({ amount: '$1,250.50', note: '' }), { amount: '1250.50' });
    assert.equal(checkArgs('set_rates', tidyArgs({ car: 'Corolla', daily: '$89' })).ok, true);
  });
});

describe('the card text of a change', () => {
  it('a payment reads as the owner asked: amount, method, invoice, owner, date', () => {
    assert.equal(summary('record_payment', { invoice: 'INV-1053', amount: 900, method: 'e_transfer', received_on: '2026-10-15' }, { owner: 'Karan Vakil' }),
      'Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?');
  });
  it('rates, a task, a payment link and dates', () => {
    assert.equal(summary('set_rates', { car: 'x', daily: 89, weekly: 500 }, { car: '2023 Toyota Corolla LE' }), 'Set the rates of the 2023 Toyota Corolla LE: $89 a day, $500 a week?');
    assert.equal(summary('create_task', { title: 'Call Maya back', queue: 'cs', priority: 'high' }), 'Add the task "Call Maya back" to the cs queue, high priority?');
    assert.match(summary('send_payment_link', { booking: 'R-000123' }, { renter: 'Maya Chen' }), /R-000123 \(Maya Chen\).*sign and pay/);
    assert.equal(shortDate('2026-10-22 14:30'), 'Oct 22, 2:30 pm');
  });
});

describe('the flow', () => {
  it('a read runs at once and its result is the answer: one model call, recorded', async () => {
    const m = stub({ action: 'tool', tool: 'today', args: {} });
    const { d, recorded } = deps(m);
    const r = await ask(d, { text: 'What needs doing today?' });
    assert.equal(m.calls, 1);
    assert.equal(r.out[0]!.type, 'results');
    assert.equal(recorded.length, 1); assert.equal(recorded[0]!.units, 12);
  });
  it('a change becomes a card with the names the database found; nothing runs before Confirm', async () => {
    const m = stub({ action: 'tool', tool: 'record_payment', args: { invoice: 'inv-1053', amount: '$900', method: 'e_transfer', reference: 'CA1234', received_on: '2026-10-15' } });
    const { d, proposed } = deps(m);
    const r = await ask(d, { text: 'Record a $900 e-transfer on INV-1053 for Karan, dated Oct 15' });
    assert.deepEqual(r.out, [{ type: 'proposal', id: 'act-1', summary: 'Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15, reference CA1234?' }]);
    assert.equal(proposed.length, 1);
    assert.equal(proposed[0]!.name, 'manual_payment_record');
    assert.deepEqual((proposed[0]!.args as Record<string, unknown>).amount_cents, 90000);
  });
  it('two cars match: it asks, listing the candidates, and proposes nothing', async () => {
    const m = stub({ action: 'tool', tool: 'publish_car', args: { car: 'Toyota' } });
    const { d, proposed } = deps(m);
    const r = await ask(d, { text: 'publish the toyota' });
    assert.equal(r.out[0]!.type, 'question');
    assert.deepEqual((r.out[0] as { options: string[] }).options, ['2023 Toyota Corolla LE (CBXT123)', '2022 Toyota Corolla SE (CDEF456)']);
    assert.equal(proposed.length, 0);
  });
  it('a plate that matches one car exactly is enough', async () => {
    const m = stub({ action: 'tool', tool: 'set_rates', args: { car: 'cbxt 123', daily: 89 } });
    const { d, proposed } = deps(m, { find: async (k) => (k === 'car' ? ROWS.car! : []) });
    const r = await ask(d, { text: 'set the daily rate of CBXT 123 to $89' });
    assert.equal(r.out[0]!.type, 'proposal');
    assert.deepEqual(proposed[0]!.args, { vehicle: 'v1', daily: '8900', weekend: '', weekly: '', monthly: '', km_mode: 'default' });
  });
  it('Mark a car insured: a car code finds the car; the card goes through the same door as Insurer confirmed (release 2)', async () => {
    const m = stub({ action: 'tool', tool: 'mark_insured', args: { car: 'cc-7f3a', on: '2026-10-20', reference: 'Fleet policy additions' } });
    const rows = [{ ...ROWS.car![0]!, car_code: 'CC-7F3A' }, { ...ROWS.car![1]!, car_code: 'CC-9B2C' }];
    const { d, proposed } = deps(m, { find: async (k) => (k === 'car' ? rows : []) });
    const r = await ask(d, { text: 'the insurer confirmed cc-7f3a on Oct 20' });
    assert.equal(r.out[0]!.type, 'proposal');
    assert.equal(proposed[0]!.name, 'insurer_confirm');
    assert.deepEqual(proposed[0]!.args, { vehicle_id: 'v1', on: '2026-10-20', note: 'Fleet policy additions' });
    assert.match((r.out[0] as { summary: string }).summary, /insured: the insurer confirmed in writing on Oct 20/);
    assert.ok(toolsFor({ portal: 'va', fn: 'fleet' }).includes('mark_insured') && !toolsFor({ portal: 'field' }).includes('mark_insured'));
  });
  it('missing details: it asks for them in words', async () => {
    const m = stub({ action: 'tool', tool: 'record_payment', args: { invoice: 'INV-1053', method: 'e_transfer', received_on: '2026-10-15' } });
    const r = await ask(deps(m).d, { text: 'record the e-transfer on INV-1053' });
    assert.equal(r.out[0]!.type, 'question');
    assert.match((r.out[0] as { text: string }).text, /reference/);
  });
  it('a tool outside the person\'s portal is not run (a field staff member cannot record a payment)', async () => {
    const m = stub({ action: 'tool', tool: 'record_payment', args: { invoice: 'INV-1053', method: 'cash', received_on: '2026-10-15' } });
    const { d, proposed } = deps(m, { who: { portal: 'field' } });
    const r = await ask(d, { text: 'record cash on INV-1053' });
    assert.equal(r.out[0]!.type, 'text'); assert.equal(proposed.length, 0);
  });
  it('a booking with no offer has no payment link to send', async () => {
    const m = stub({ action: 'tool', tool: 'send_payment_link', args: { booking: 'R-000123' } });
    const { d } = deps(m, { find: async () => [{ id: 'b1', booking_number: 'R-000123', status: 'confirmed' }] });
    const r = await ask(d, { text: 'send the payment link for R-000123' });
    assert.match((r.out[0] as { text: string }).text, /no offer to pay/);
  });
  it('a rental already underway says so on its card and is sent with instants', async () => {
    const m = stub({ action: 'tool', tool: 'add_rental', args: { car: 'CBXT123', pickup_at: '2026-10-20 10:00', return_at: '2026-10-27 10:00', renter_name: 'Maya Chen', renter_email: 'maya@example.test', renter_mobile: '416 555 0100' } });
    const { d, proposed } = deps(m, { find: async (k) => (k === 'car' ? [ROWS.car![0]!] : []) });
    const r = await ask(d, { text: 'add a rental' });
    assert.match((r.out[0] as { summary: string }).summary, /already underway/);
    assert.equal((proposed[0]!.args as Record<string, string>).pickup_at, '2026-10-20T10:00:00-04:00');
  });
});

describe('paused states (the usage guard)', () => {
  it('the gate closed: the assistant says it rests until tomorrow, and the model is not called', async () => {
    const m = stub({ action: 'reply', reply: 'hi' });
    const r = await ask(deps(m, { gate: async () => ({ ok: false, paused: true }) }).d, { text: 'What needs doing today?' });
    assert.deepEqual(r.out, [{ type: 'paused', text: PAUSE.assistant }]);
    assert.equal(m.calls, 0);
  });
  it('Workers AI refusing for its allowance reads the same, never an error', async () => {
    const m: AssistantModel = { name: 'workers-ai', service: 'workers_ai', step: async () => ({ ok: false, reason: 'quota', message: '4006' }) };
    const r = await ask(deps(m).d, { text: 'hello' });
    assert.deepEqual(r.out, [{ type: 'paused', text: PAUSE.assistant }]);
  });
  it('Claude without an allowed budget says where to allow it', () => {
    assert.equal(pauseMessage('assistant', { ok: false, service: 'claude' }), PAUSE.assistantClaude);
    assert.match(PAUSE.assistantClaude, /Settings > Usage/);
  });
  it('the words of every paused feature', () => {
    assert.equal(PAUSE.chat, 'Our assistant is resting until tomorrow. A person will answer you here.');
    assert.equal(PAUSE.assistant, 'Today\'s free AI allowance is used up. The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups.');
    for (const v of Object.values(PAUSE)) { assert.doesNotMatch(v, /error|failed|—|–/i); assert.doesNotMatch(v, /Carmacars|Carma Cars/); }
    assert.equal(pauseMessage('chat', { ok: true }), null);
  });
  it('what continuing costs, and what cannot be paid', () => {
    const ai = paidCost({ service: 'workers_ai', unit: 'neurons', usd_per_unit: 0.000011, included: 10000, period: 'day', pause_mode: 'pause', upgrade_text: null, overage_usd: 0 });
    // Workers AI is a hard stop at the free allowance (0133): never paid
    assert.equal(ai.rate, 'Free allowance only: never paid.'); assert.match(ai.example, /midnight, Toronto time/); assert.equal(ai.canPay, false);
    assert.equal(paidCost({ service: 'images', unit: 'transformations', usd_per_unit: 0.0005, included: 5000, period: 'month', pause_mode: 'pause', upgrade_text: null, overage_usd: 0 }).canPay, true);
    const mail = paidCost({ service: 'resend_day', unit: 'emails', usd_per_unit: null, included: 100, period: 'day', pause_mode: 'hold', upgrade_text: 'Resend Pro', overage_usd: 0 });
    assert.equal(mail.canPay, false);
    assert.equal(usedUpTitle({ label: 'Workers AI (assistant, live chat)', period: 'day' }), 'Included Workers AI used up for today');
    assert.equal(capProblem('5'), null); assert.match(capProblem('0')!, /US\$0\.01/); assert.match(capProblem('abc')!, /in US dollars/);
  });
});

describe('the models', () => {
  it('the stub picks the tool a sentence asks for', () => {
    const all = Object.keys(TOOLS) as ToolName[];
    assert.equal(fakeStep('What needs doing today?', all).tool, 'today');
    const p = fakeStep('Record a $900 e-transfer on INV-1053 dated 2026-10-15 ref CA12345', all);
    assert.deepEqual([p.tool, p.args?.amount, p.args?.invoice, p.args?.reference], ['record_payment', 900, 'INV-1053', 'CA12345']);
    assert.equal(fakeStep('Is the Corolla free from 2026-11-02 to 2026-11-04?', all).args?.car, 'Corolla');
    assert.equal(fakeStep('who has the Tesla?', all).tool, 'who_has_car');
  });
  it('Claude: a tool call becomes a step and its cost is counted in micro-dollars', async () => {
    let body = '';
    const m = claudeModel({ key: 'k', model: 'claude-haiku-4-5', inUsdPerM: 1, outUsdPerM: 5, fetch: async (_u, i) => { body = i.body; return { ok: true, status: 200, json: async () => ({ content: [{ type: 'tool_use', name: 'find', input: { kind: 'car', q: 'Corolla' } }], usage: { input_tokens: 1000, output_tokens: 100 } }) }; } });
    const r = await m.step('sys', [{ role: 'user', text: 'find the corolla' }], ['find']);
    assert.ok(r.ok);
    if (r.ok) { assert.deepEqual(r.step, { action: 'tool', tool: 'find', args: { kind: 'car', q: 'Corolla' } }); assert.deepEqual(r.usage, { units: 1500, unit: 'microusd' }); }
    const sent = JSON.parse(body) as { tools: Array<{ name: string }>; model: string };
    assert.deepEqual(sent.tools.map((t) => t.name), ['find', 'ask']); assert.equal(sent.model, 'claude-haiku-4-5');
  });
  it('Claude answering 429 is a quota refusal (the assistant pauses)', async () => {
    const m = claudeModel({ key: 'k', model: 'm', inUsdPerM: 1, outUsdPerM: 5, fetch: async () => ({ ok: false, status: 429, json: async () => ({ error: { message: 'rate limited' } }) }) });
    const r = await m.step('s', [{ role: 'user', text: 'x' }], []);
    assert.equal(r.ok ? 'ok' : r.reason, 'quota');
  });
});

// ---------------------------------------------------------------- 0133: the budget's words, offers, rentals, balances
const PREVIEW = { ok: true, available: true, booking: { billable_days: 2, deposit_cents: 50000, hst_at_booking_cents: 2600, total_due_at_booking_cents: 22600, renter_due_at_booking_cents: 22600,
  lines: [{ charge_type: 'rental_charge', description: 'Rental, 2 days', amount_cents: 18000, stage: 'booking', charged_to_renter: true },
          { charge_type: 'cleaning', description: null, amount_cents: 2000, stage: 'booking', charged_to_renter: true },
          { charge_type: 'damage', description: 'Later charge', amount_cents: 9900, stage: 'post_rental', charged_to_renter: true }] } };
function staffDeps(m: AssistantModel, over: Partial<Record<'offer_preview' | 'offer_form' | 'find_customers' | 'booking_money', unknown>> = {}, who: Deps['who'] = { portal: 'admin' }) {
  const calls: Array<{ what: string; p: Record<string, unknown> }> = [];
  const base = deps(m, { who, find: async (k, q) => (k === 'car' ? ROWS.car!.filter((r) => String(r.plate).toLowerCase() === q.toLowerCase().replace(/\s/g, '') || q.toLowerCase() === 'corolla le' && r.id === 'v1') : k === 'booking' ? ROWS.booking! : []) });
  base.d.staff = async (what, p) => {
    calls.push({ what, p });
    const o = over[what];
    const v = typeof o === 'function' ? (o as (x: Record<string, unknown>) => unknown)(p) : o ?? (what === 'offer_preview' ? PREVIEW : what === 'find_customers' ? [] : what === 'offer_form' ? { cars: [] } : {});
    if (v instanceof Error) throw v;
    return v as Record<string, unknown>;
  };
  return { ...base, calls };
}

describe('the budget\'s words (0133)', () => {
  it('a closed gate shows the database\'s message: how much is used and when the assistant is back', async () => {
    const msg = 'Today\'s free AI allowance is used up (10,412 of 10,000 neurons). The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups.';
    const m = stub({ action: 'reply', reply: 'x' });
    const r = await ask(deps(m, { gate: async () => ({ ok: false, message: msg }) }).d, { text: 'hello' });
    assert.deepEqual(r.out, [{ type: 'paused', text: msg }]);
    assert.equal(m.calls, 0);
  });
  it('Claude\'s closed gate keeps its own words (no new spend without an Admin)', () => {
    assert.equal(pauseMessage('assistant', { ok: false, service: 'claude', message: 'other' }), PAUSE.assistantClaude);
  });
});

describe('offers and rentals through the assistant (0133)', () => {
  it('who sees the offer tools: Admin, customer service and sales; never Fleet or field staff', () => {
    assert.ok(toolsFor({ portal: 'admin' }).includes('create_offer'));
    assert.ok(toolsFor({ portal: 'va', fn: 'cs' }).includes('create_offer') && toolsFor({ portal: 'va', fn: 'sales' }).includes('create_offer'));
    assert.ok(!toolsFor({ portal: 'va', fn: 'fleet' }).includes('create_offer') && !toolsFor({ portal: 'field' }).includes('create_offer'));
    assert.ok(toolsFor({ portal: 'va', fn: 'finance' }).includes('booking_balance'));
  });
  it('the customer is needed: one on file, or a new one\'s name, email and mobile', () => {
    const c = checkArgs('create_offer', { car: 'Corolla', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00' });
    assert.equal(c.ok, false); assert.match(!c.ok ? c.problem : '', /the customer/);
    assert.equal(checkArgs('create_offer', { car: 'Corolla', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'maya@example.com' }).ok, true);
    const typed = checkArgs('create_offer', { car: 'Corolla', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'Maya', rental_total: 150 });
    assert.match(!typed.ok ? typed.problem : '', /why the rental price differs/);
  });
  it('create an offer: the card has the customer on file, the car, the dates, the price lines, the deposit and how it is paid and sent; nothing runs', async () => {
    const m = stub({ action: 'tool', tool: 'create_offer', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'maya@example.com', deposit_pay: 'cash', notify: 'both' } });
    const { d, proposed, calls } = staffDeps(m, { find_customers: [{ id: 'r1', legal_name: 'Maya Chen', email: 'maya@example.com', mobile: '4165550100', date_of_birth: '1990-01-01', is_blocked: false }] });
    const r = await ask(d, { text: 'send an offer' });
    const card = r.out[0] as { type: string; summary: string; details: Array<{ title: string; rows: Array<{ label: string; value: string }> }> };
    assert.equal(card.type, 'proposal');
    assert.equal(card.summary, 'Send an offer for the 2023 Toyota Corolla LE to Maya Chen, Nov 2, 10:00 am to Nov 4, 10:00 am: $226.00 due at booking, by email and text?');
    const rows = Object.fromEntries(card.details.flatMap((x) => x.rows.map((y) => [y.label, y.value])));
    assert.equal(rows.Customer, 'Maya Chen · maya@example.com · 4165550100 (on file)');
    assert.equal(rows['Rental, 2 days'], '$180.00'); assert.equal(rows.Cleaning, '$20.00'); assert.equal(rows.HST, '$26.00');
    assert.equal(rows['Due at booking'], '$226.00'); assert.equal(rows['Deposit (refundable)'], '$500.00');
    assert.equal(rows.Deposit, '$500.00 by cash at pickup'); assert.equal(rows['Later charge'], undefined);
    assert.equal(proposed.length, 1);
    assert.equal(proposed[0]!.name, 'offer_create');
    const a = proposed[0]!.args as Record<string, unknown>;
    assert.deepEqual([a.renter_id, a.vehicle_id, a.deposit_pay_method, a.notify, a.channels], ['r1', 'v1', 'cash', true, { email: true, text: true }]);
    assert.ok((proposed[0]!.details as unknown[]).length >= 3);
    // the same payload was previewed (rolled back) before the card
    assert.deepEqual(calls.map((c) => c.what), ['find_customers', 'offer_preview']);
    assert.deepEqual(calls[1]!.p, a);
  });
  it('a refused preview (the car not bookable, a blocked customer) is said, and no card is made', async () => {
    const m = stub({ action: 'tool', tool: 'create_offer', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', renter_name: 'New Person', renter_email: 'np@example.com', renter_mobile: '4165550199', renter_date_of_birth: '1995-05-05' } });
    const { d, proposed } = staffDeps(m, { offer_preview: { ok: false, error: 'ERROR:  The car is not available for those dates' } });
    const r = await ask(d, { text: 'offer' });
    assert.deepEqual(r.out, [{ type: 'text', text: 'The offer cannot be made: The car is not available for those dates. Nothing was sent.' }]);
    assert.equal(proposed.length, 0);
  });
  it('a new customer without a date of birth is asked for it before an offer', async () => {
    const m = stub({ action: 'tool', tool: 'create_offer', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', renter_name: 'New Person', renter_email: 'np@example.com', renter_mobile: '4165550199' } });
    const { d, proposed } = staffDeps(m);
    const r = await ask(d, { text: 'offer' });
    assert.equal(r.out[0]!.type, 'question'); assert.match((r.out[0] as { text: string }).text, /date of birth/);
    assert.equal(proposed.length, 0);
  });
  it('two customers match: it asks which one', async () => {
    const m = stub({ action: 'tool', tool: 'create_offer', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'Chen' } });
    const { d, proposed } = staffDeps(m, { find_customers: [{ id: 'r1', legal_name: 'Maya Chen', email: 'm@example.com' }, { id: 'r2', legal_name: 'Leo Chen', email: 'l@example.com' }] });
    const r = await ask(d, { text: 'offer' });
    assert.deepEqual(r.out[0], { type: 'question', text: 'More than one customer matches "Chen". Which one?', options: ['Maya Chen, m@example.com', 'Leo Chen, l@example.com'] });
    assert.equal(proposed.length, 0);
  });
  it('add a rental: the same card with price lines and the payments (paid by e-Transfer, deposit in cash, signed on paper)', async () => {
    const m = stub({ action: 'tool', tool: 'add_rental', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'maya@example.com', payment: 'other_way', method: 'e_transfer', reference: 'CA99', amount: 226, deposit_method: 'cash', agreement: 'paper' } });
    const { d, proposed } = staffDeps(m, { find_customers: [{ id: 'r1', legal_name: 'Maya Chen', email: 'maya@example.com', mobile: '4165550100', date_of_birth: '1990-01-01' }] });
    const r = await ask(d, { text: 'add a rental' });
    const card = r.out[0] as { summary: string; details: Array<{ rows: Array<{ label: string; value: string }> }> };
    const rows = Object.fromEntries(card.details.flatMap((x) => x.rows.map((y) => [y.label, y.value])));
    assert.match(card.summary, /^Add a rental of the 2023 Toyota Corolla LE for Maya Chen, Nov 2, 10:00 am to Nov 4, 10:00 am, paid by e-Transfer \(\$226\)/);
    assert.equal(rows.Rental, 'Paid by e-Transfer ($226), reference CA99');
    assert.equal(rows.Deposit, 'By cash ($500.00)'); assert.match(rows.Agreement!, /paper/);
    assert.equal(proposed[0]!.name, 'manual_rental_create');
    const a = proposed[0]!.args as Record<string, unknown>;
    assert.deepEqual([a.renter_id, a.deposit, a.agreement, (a.payment as Record<string, unknown>).amount_cents], ['r1', { method: 'cash' }, 'paper', 22600]);
  });
  it('field staff (no offer screen): the rental card says the price is worked out when added', async () => {
    const m = stub({ action: 'tool', tool: 'add_rental', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', renter_name: 'New Person', renter_email: 'np@example.com', renter_mobile: '4165550199' } });
    const { d, proposed } = staffDeps(m, { offer_preview: new Error('ERROR:  An Admin, customer service or sales sends an offer') }, { portal: 'field' });
    const r = await ask(d, { text: 'add' });
    const card = r.out[0] as { details: Array<{ title: string; rows: Array<{ value: string }> }> };
    assert.match(card.details.find((x) => x.title === 'Price')!.rows[0]!.value, /when it is added/);
    assert.equal(proposed.length, 1);
  });
  it('a payment on a booking is recorded by part, through the screen\'s function', async () => {
    const m = stub({ action: 'tool', tool: 'record_payment', args: { booking: 'R-000123', covers: 'fees', amount: 20, method: 'cash', received_on: '2026-10-21' } });
    const { d, proposed } = staffDeps(m);
    const r = await ask(d, { text: 'record' });
    assert.equal((r.out[0] as { summary: string }).summary, 'Record a $20 cash on booking R-000123 for Maya Chen (fees), dated Oct 21?');
    assert.deepEqual([proposed[0]!.name, (proposed[0]!.args as Record<string, unknown>).covers, (proposed[0]!.args as Record<string, unknown>).amount_cents], ['record_booking_payment', 'fees', 2000]);
  });
  it('what does a renter owe: each open booking\'s parts and the deposit', async () => {
    const m = stub({ action: 'tool', tool: 'booking_balance', args: { customer: 'Maya' } });
    const { d } = staffDeps(m, { booking_money: { booking_number: 'R-000123', status: 'offered', parts: [{ covers: 'rental', open_cents: 20600 }, { covers: 'fees', open_cents: 2000 }, { covers: 'later', open_cents: 0 }], deposit_cents: 50000, deposit_pay_method: 'card', deposit: null } });
    const r = await ask(d, { text: 'what does Maya owe' });
    const res = r.out[0] as { title: string; rows: Array<{ title: string; sub: string; href: string }> };
    assert.equal(res.title, 'What "Maya" owes');
    assert.deepEqual(res.rows[0], { title: 'R-000123: $226.00 owing', sub: 'offered · rental $206.00 · fees $20.00 · later $0.00 · deposit $500.00 not taken yet (card)', href: '/admin/bookings/R-000123?tab=money' });
  });
  it('which car is free: every bookable car from the offer screen, with its rates; the public search when that is not allowed', async () => {
    const m = stub({ action: 'tool', tool: 'availability', args: { pickup_date: '2026-11-02', return_date: '2026-11-04' } });
    const { d, calls } = staffDeps(m, { offer_form: { cars: [{ id: 'v1', name: '2023 Toyota Corolla LE', plate: 'CBXT123', free: true, daily_rate_cents: 9000 }, { id: 'v2', name: '2022 Toyota Corolla SE', plate: 'CDEF456', free: false }] } });
    const r = await ask(d, { text: 'free?' });
    assert.deepEqual(r.out[0], { type: 'results', title: 'Free from 2026-11-02 to 2026-11-04', empty: 'No car is free on those dates.', rows: [{ title: '2023 Toyota Corolla LE (CBXT123)', sub: '$90.00 a day', href: '/admin/vehicles/v1' }] });
    assert.equal(calls[0]!.what, 'offer_form');
    const f = staffDeps(stub({ action: 'tool', tool: 'availability', args: { pickup_date: '2026-11-02', return_date: '2026-11-04', car: 'Corolla' } }), { offer_form: new Error('ERROR:  An Admin, customer service or sales sends an offer') }, { portal: 'field' });
    const r2 = await ask(f.d, { text: 'free?' });
    assert.match((r2.out[0] as { text: string }).text, /^Yes: the 2023 Toyota Corolla is free/);
  });
});

// 2026-10-27: a preview that prices like the database: the rental charge (the rates' $180.00, or typed plus tax, or typed tax
// included: before tax backed out, the HST what is left), a $20.00 cleaning fee, the Protection Plan set by hand; HST 13%.
function pricing(p: Record<string, unknown>) {
  const bps = 1300;
  const w = p.rental_charge_cents as number | undefined;
  const rental = w === undefined ? { amount_cents: 18000, hst_cents: hstOf(18000, bps) } : p.price_tax === 'included' ? { amount_cents: beforeTax(w, bps), hst_cents: w - beforeTax(w, bps) } : { amount_cents: w, hst_cents: hstOf(w, bps) };
  const plan = (p.line_overrides as Record<string, number> | undefined)?.coverage_sold;
  const lines = [{ charge_type: 'rental_charge', description: 'Rental, 2 days', ...rental, stage: 'booking', charged_to_renter: true },
    { charge_type: 'cleaning', description: null, amount_cents: 2000, hst_cents: 260, stage: 'booking', charged_to_renter: true },
    ...(plan !== undefined ? [{ charge_type: 'coverage_sold', description: 'Protection Plan', amount_cents: plan, hst_cents: hstOf(plan, bps), stage: 'booking', charged_to_renter: true }] : [])];
  const sub = lines.reduce((x, l) => x + l.amount_cents, 0); const hst = lines.reduce((x, l) => x + l.hst_cents, 0);
  return { ok: true, available: true, booking: { billable_days: 2, hst_bps: bps, deposit_cents: 50000, hst_at_booking_cents: hst, total_due_at_booking_cents: sub + hst, renter_due_at_booking_cents: sub + hst, lines } };
}

describe('amounts said after tax (2026-10-27)', () => {
  const customer = { find_customers: [{ id: 'r1', legal_name: 'Maya Chen', email: 'maya@example.com', mobile: '4165550100', date_of_birth: '1990-01-01', is_blocked: false }], offer_preview: pricing };
  it('the arguments: tax included, the total after tax and the plan price are taken (amounts as text too); not a rental price and a total both', () => {
    assert.deepEqual(tidyArgs({ total_after_tax: '$320', plan_price: '$50.00', rental_total: '1,270' }), { total_after_tax: '320', plan_price: '50.00', rental_total: '1270' });
    assert.equal(checkArgs('create_offer', { car: 'Corolla', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'Maya', total_after_tax: 320, plan_price: 50, tax_included: true }).ok, true);
    const both = checkArgs('add_rental', { car: 'Corolla', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'Maya', rental_total: 270, total_after_tax: 320 });
    assert.match(!both.ok ? both.problem : '', /not both/);
    assert.match(systemPrompt({ portal: 'admin' }, '2026-10-27', ['create_offer']), /total_after_tax/);
  });
  it('"$270 after tax for the rental and $50 after tax for the Protection Plan": the plan goes before tax, the rental tax included, $340.60 with the cleaning fee', async () => {
    const m = stub({ action: 'tool', tool: 'create_offer', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'maya@example.com', rental_total: 270, plan_price: 50, tax_included: true, price_reason: 'Paid cash' } });
    const { d, proposed } = staffDeps(m, customer);
    await ask(d, { text: 'offer' });
    const a = proposed[0]!.args as Record<string, unknown>;
    assert.deepEqual([a.rental_charge_cents, a.price_tax, a.line_overrides, a.coverage_option], [27000, 'included', { coverage_sold: 4425 }, 3]);
    const rows = Object.fromEntries((proposed[0]!.details as Array<{ rows: Array<{ label: string; value: string }> }>).flatMap((x) => x.rows.map((y) => [y.label, y.value])));
    assert.equal(rows['Due at booking'], '$342.60');
    assert.match(rows['Amounts said']!, /After tax/);
  });
  it('"$320 total after tax": the rental charge is worked out so the total is exactly $320.00, the rounding on the rental line', async () => {
    const m = stub({ action: 'tool', tool: 'add_rental', args: { car: 'CBXT123', pickup_at: '2026-11-02 10:00', return_at: '2026-11-04 10:00', customer: 'maya@example.com', total_after_tax: 320, plan_price: 50, tax_included: true } });
    const { d, proposed } = staffDeps(m, customer);
    await ask(d, { text: 'add a rental, $320 total after tax' });
    const a = proposed[0]!.args as Record<string, unknown>;
    // 320.00 - plan 50.00 - cleaning 22.60 = rental 247.40 with HST (218.94 + 28.46)
    assert.deepEqual([a.rental_charge_cents, a.price_tax, a.line_overrides], [24740, 'included', { coverage_sold: 4425 }]);
    assert.equal(pricing(a).booking.total_due_at_booking_cents, 32000);
    const rows = Object.fromEntries((proposed[0]!.details as Array<{ rows: Array<{ label: string; value: string }> }>).flatMap((x) => x.rows.map((y) => [y.label, y.value])));
    assert.equal(rows['Due at booking'], '$320.00');
    assert.equal(rows.Check, undefined);
    assert.match(String(a.price_reason), /Total agreed with the customer: \$320\.00 with HST/);
  });
});
