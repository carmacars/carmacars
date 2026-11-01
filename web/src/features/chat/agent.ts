// Live chat (migration 0060): the AI assistant. One visitor message in, one reply (or a hand-over to a person) out.
// The model never computes a price: it asks for a quote or a search through the tools below, which call the
// database's own pricing functions, and its reply may only repeat amounts those calls returned (guardrails.ts). It
// can start a booking request (a lead and a task for Sales) and hand over to a person. Dependencies are passed in,
// so the unit tests run it with a stub model and stub tools (agent.test.ts).
import { centsIn, checkReply, escalationFor, ESCALATION_WORDS, money, tidy, type Escalation, type ReplyContext } from './guardrails.ts';

export interface FleetCar { slug: string; name: string; class: string; seats: number; transmission: string; fuel: string; area?: string; daily_rate_cents: number; weekly_rate_cents?: number; deposit_cents: number; km_per_day?: number; young_18_20?: boolean; vehicle_id: string; taking_requests?: boolean; sample?: boolean; code?: string | null }
export interface ChatFacts {
  today: string; weekday: string;
  site: { brand?: string; city?: string; phone?: string; email?: string | null; hours?: string; reply?: string; service_area?: string; delivery_area?: string | null };
  rules: { min_age?: number; standard_min_age?: number; max_days?: number; licences?: string[]; notice_minutes?: number; offer_hours?: number; non_refundable_discount_bps?: number;
    cancellation?: Record<string, number>; deposit_release_days?: number; airports?: Array<{ code: string; name: string; surcharge_cents: number }>; max_additional_drivers?: number; hst_bps?: number;
    fees?: Record<string, { label: string; unit: string; amount_cents?: number; cap_cents?: number }> };
  fleet: FleetCar[];
  never_say: string[];
}
export interface QuoteResult { available: boolean; problems?: Array<{ code: string; message: string }>; lines?: Array<{ label: string; amount_cents: number }>; hst_cents?: number; total_cents?: number; deposit_cents?: number; billable_days?: number; km_allowance_total?: number }
export interface SearchRow { slug: string; make: string; model: string; vehicle_year: number; seats: number; vehicle_class: string; billable_days: number; total_cents: number; deposit_cents: number; daily_rate_cents: number }
export interface Usage { inputTokens: number; outputTokens: number; neurons: number }
export type ModelCall = (system: string, prompt: string) => Promise<{ ok: true; data: Step; usage: Usage; model: string } | { ok: false; reason: string; message: string; usage?: Usage }>;
export interface AgentDeps {
  model: ModelCall;
  facts: ChatFacts;
  quote(vehicleId: string, pickupIso: string, returnIso: string): Promise<QuoteResult>;
  search(pickupIso: string, returnIso: string, filters: Record<string, unknown>): Promise<SearchRow[]>;
  lead(args: Record<string, string | number | undefined>): Promise<{ ok: boolean; missing?: string; reference?: string }>;
  instant(date: string, time: string): string;
}
export interface Step {
  action: 'reply' | 'search_cars' | 'quote' | 'start_request' | 'handoff';
  reply?: string; car?: string; pickup_date?: string; return_date?: string; pickup_time?: string; return_time?: string;
  seats?: number; class?: string; name?: string; email?: string; phone?: string; note?: string; reason?: string;
}
export interface Turn { sender: 'visitor' | 'ai' | 'staff' | 'system'; body: string; meta?: Record<string, unknown> }
export interface AgentInput { history: Turn[]; text: string; page?: string | null; car?: string | null; name?: string | null; email?: string | null; phone?: string | null }
export interface AgentResult {
  reply?: string; handoff?: { reason: string; escalation?: Escalation }; neurons: number; model?: string; ok: boolean; error?: string;
  meta: { tools: Array<{ name: string; args: Record<string, unknown>; ok: boolean }>; quote_total_cents?: number; refused?: string[]; car?: string; cents?: number[]; faq?: string };
}

export const STEP_SCHEMA = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: ['reply', 'search_cars', 'quote', 'start_request', 'handoff'] },
    reply: { type: 'string' }, car: { type: 'string' }, pickup_date: { type: 'string' }, return_date: { type: 'string' },
    pickup_time: { type: 'string' }, return_time: { type: 'string' }, seats: { type: 'integer' }, class: { type: 'string' },
    name: { type: 'string' }, email: { type: 'string' }, phone: { type: 'string' }, note: { type: 'string' }, reason: { type: 'string' }
  },
  required: ['action']
} as const;

const pct = (bps?: number) => (typeof bps === 'number' ? `${bps / 100}%` : '');

const lc = (s: string) => s.toLowerCase();
/** The cars a message or the conversation names: by slug, car code, or make and model ("toyota corolla", "corolla"). */
export function carsNamed(f: Pick<ChatFacts, 'fleet'>, text: string): FleetCar[] {
  const t = lc(text);
  const codes = new Set(codesIn(text).map((c) => carByCode(f, c)?.slug).filter(Boolean));
  return f.fleet.filter((c) => {
    if (codes.has(c.slug) || t.includes(c.slug.replace(/-/g, ' ')) || t.includes(c.slug)) return true;
    const words = lc(c.name).replace(/^\d{4} /, '').split(' ');
    const model = words[1];
    return t.includes(words.slice(0, 2).join(' ')) || (!!model && model.length >= 4 && new RegExp(`\\b${model.replace(/[^a-z0-9]/g, '')}\\b`).test(t));
  });
}

/** The cars the prompt lists (0370): the car on the visitor's page and the cars the conversation names first, then a
 *  few others across classes, at most `max`. The whole fleet in every prompt cost about 250 neurons a step. */
export function focusFleet(f: ChatFacts, focus: { car?: string | null; text?: string } = {}, max = 12): FleetCar[] {
  const open = f.fleet.filter((x) => x.taking_requests !== false);
  if (open.length <= max) return open;
  const out: FleetCar[] = [];
  const add = (c?: FleetCar) => { if (c && !out.includes(c) && out.length < max) out.push(c); };
  add(open.find((c) => c.slug === focus.car));
  for (const c of carsNamed({ fleet: open }, focus.text ?? '')) add(c);
  // then the cheapest of each class, then the cheapest overall
  const byPrice = [...open].sort((a, b) => a.daily_rate_cents - b.daily_rate_cents);
  for (const cls of [...new Set(byPrice.map((c) => c.class))]) add(byPrice.find((c) => c.class === cls && !c.sample));
  for (const c of byPrice) add(c);
  return out;
}

/** The facts, written compactly (fewer tokens, fewer neurons). Every amount here may be repeated by the assistant. */
export function factsText(f: ChatFacts, focus?: { car?: string | null; text?: string }, max = 12): string {
  const r = f.rules, c = r.cancellation ?? {};
  const listed = focus ? focusFleet(f, focus, max) : f.fleet.filter((x) => x.taking_requests !== false);
  const open = f.fleet.filter((x) => x.taking_requests !== false);
  const cheapest = open.length ? Math.min(...open.map((x) => x.daily_rate_cents)) : 0;
  const cars = listed.map((x) =>
    `${x.slug}${x.code ? ` (car code ${x.code})` : ''} | ${x.name} | ${x.class}, ${x.seats} seats, ${x.transmission}, ${x.fuel} | from ${money(x.daily_rate_cents)} a day | Deposit ${money(x.deposit_cents)}${x.km_per_day ? ` | ${x.km_per_day} km a day included` : ''}${x.young_18_20 ? ' | drivers 18 to 20 allowed' : ''}${x.area ? ` | ${x.area}` : ''}${x.sample ? ' | EXAMPLE CAR (a sample, not a real car: never quote or promise it; take a request and say we will suggest a similar real car)' : ''}`).join('\n');
  const fees = Object.values(r.fees ?? {}).filter((x) => typeof x.amount_cents === 'number')
    .map((x) => `${x.label}: ${money(x.amount_cents!)}${x.unit === 'per_day' ? ' a day' : ''}${x.cap_cents ? `, up to ${money(x.cap_cents)}` : ''}`).join('; ');
  return [
    `Today is ${f.weekday}, ${f.today} (Toronto).`,
    `Company: ${f.site.brand ?? 'CarmaCars'}, car rental in ${f.site.service_area ?? f.site.city ?? 'Toronto'}. Phone ${f.site.phone ?? ''}. Hours: ${f.site.hours ?? ''}. Replies to requests ${f.site.reply ?? 'quickly'}.`,
    `How booking works (request to book): the visitor sends a booking request on the car's page (Book this car). We check it and send an offer by email within ${f.site.reply ?? 'a short time'}. The offer is valid ${r.offer_hours ?? 24} hours. The renter approves the offer, signs the rental agreement online and pays by credit card; only then is the car booked. Nothing is booked or held before payment.`,
    `Requirements: age ${r.min_age ?? 18}+ (${r.standard_min_age ?? 21}+ for every car; drivers 18 to 20 only on cars marked so, with a young driver fee), a full Ontario licence (classes ${(r.licences ?? ['G']).join(', ')}; others reviewed by staff), a credit card in the renter's name, a licence photo and a selfie checked by our staff before pickup. Up to ${r.max_additional_drivers ?? 4} additional drivers. Rentals up to ${r.max_days ?? 30} days; book at least ${Math.round((r.notice_minutes ?? 120) / 60)} hours ahead.`,
    `Deposit: a hold on the credit card, the amount per car below, released within ${r.deposit_release_days ?? 7} business days after the return when nothing is owed.`,
    `Cancellation: full refund less 5% within ${c.grace_hours ?? 24} hours of booking (if pickup is more than ${c.early_hours ?? 48} hours away); ${pct(c.early_bps)} refund ${c.early_hours ?? 48}+ hours before pickup; ${pct(c.mid_bps)} refund ${c.late_hours ?? 24} to ${c.early_hours ?? 48} hours before; ${pct(c.late_bps)} under ${c.late_hours ?? 24} hours. A non-refundable booking is ${pct(r.non_refundable_discount_bps)} cheaper and is never refunded.`,
    `Delivery: pickup at our location or delivery for a fee shown in the quote; airports: ${(r.airports ?? []).map((a) => a.name).join(', ')}.`,
    `Protection Plan: optional, offered with the booking; its price is in the offer. Call it only "the Protection Plan". Do not explain what it pays for: a person answers those questions.`,
    `Fees: ${fees}. Prices on the site and in quotes are before HST (${pct(r.hst_bps)}) unless the quote says the total.`,
    `Each car has a short car code (like CC-7F3A) shown on its page: a visitor may name a car by it.`,
    `Cars (slug | name | details | price from | deposit):\n${cars}`,
    ...(listed.length < open.length ? [`These are ${listed.length} of our ${open.length} cars (from ${money(cheapest)} a day). For other cars or what is free on dates, call search_cars.`] : [])
  ].join('\n');
}

/** Common questions answered from the facts with no model call (0370: no neurons, the same answer every time). Only
 *  for a short message about one topic with no dates and no car: anything more goes to the model. */
export function faqReply(f: ChatFacts, text: string): { topic: string; reply: string } | null {
  const t = lc(text.trim());
  if (t.length > 160 || /\d{4}-\d{2}-\d{2}|\b(today|tomorrow|tonight|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week)\b/.test(t)) return null;
  if (carsNamed(f, text).length || codesIn(text).length) return null;
  const r = f.rules, c = r.cancellation ?? {};
  const topics: Array<[string, RegExp, () => string]> = [
    ['deposit', /\bdeposit\b/, () => `The deposit is a hold on your credit card, not a charge. Each car shows its deposit on its page, and the hold is released within ${r.deposit_release_days ?? 7} business days after the return when nothing is owed.`],
    ['requirements', /\b(how old|age|young driver|under 2[15]|requirements?|licen[cs]e|what do i need)\b/, () => `You need to be ${r.standard_min_age ?? 21} or older (drivers 18 to 20 only on cars marked so), with a full Ontario licence (${(r.licences ?? ['G']).join(', ')}) and a credit card in your name. We check a licence photo and a selfie before pickup.`],
    ['booking', /\b(how (do|can) i (book|rent|reserve)|how does (it|booking|renting) work|how to (book|rent))\b/, () => `Send a booking request on the car's page (Book this car). We check it and email you an offer, valid ${r.offer_hours ?? 24} hours. You approve it, sign online and pay by credit card; only then is the car booked.`],
    ['cancellation', /\b(cancel|cancellation|refund policy)\b/, () => `Cancelling ${c.early_hours ?? 48} hours or more before pickup refunds ${pct(c.early_bps)}; ${c.late_hours ?? 24} to ${c.early_hours ?? 48} hours before, ${pct(c.mid_bps)}; under ${c.late_hours ?? 24} hours, ${pct(c.late_bps)}. A non-refundable booking is cheaper and is never refunded.`],
    ['hours', /\b(opening hours|your hours|hours of operation|when are you open|what time do you (open|close))\b/, () => `Our hours: ${f.site.hours ?? 'see the Contact page'}. You can send a booking request on the site any time.`],
    ['delivery', /\b(deliver|delivery|airport|drop off|pick ?up location|where do i pick)\b/, () => `Pick up at our location, or we deliver for a fee shown in your quote${(r.airports ?? []).length ? `, including ${(r.airports ?? []).map((a) => a.name).join(' and ')}` : ''}.`]
  ];
  const hits = topics.filter(([, re]) => re.test(t));
  if (hits.length !== 1) return null;
  return { topic: hits[0]![0], reply: hits[0]![2]() };
}

/** The question the assistant adds to its first answer when we have no phone or email yet (0370). */
export const CONTACT_ASK = 'In case we get cut off, what is the best phone number or email to reach you?';
const asksContact = (s: string) => /\b(phone|number|email|e-mail)\b/i.test(s);
/** A reply with the contact question added, when it is the first answer and nothing asks it already. */
export function withContactAsk(reply: string, input: Pick<AgentInput, 'email' | 'phone' | 'history'>): string {
  if (input.email || input.phone || asksContact(reply)) return reply;
  if (input.history.some((t) => t.sender === 'ai' && !(t.meta as { greeting?: boolean } | undefined)?.greeting)) return reply;
  return `${reply} ${CONTACT_ASK}`;
}

export const SYSTEM = `You are the CarmaCars assistant in the live chat of carmacars.ca, a car rental company in Toronto.
Answer in plain, friendly, short sentences (at most 4 sentences). Never use long dashes. Write the brand as CarmaCars.
Use only the FACTS and the TOOL RESULTS. Never invent a price, a fee, a date, a car or a policy. Never compute a price yourself: for a price or availability on dates, call the tool "quote" (one car) or "search_cars" (which cars are free), then copy the amounts exactly as the tool result gives them.
Never offer a discount, a promo code or a price change. Never promise a car is held, booked or confirmed: only a paid booking is booked. Never give legal or insurance advice and never say the words insurance or coverage; never name any provider. The optional protection is called the Protection Plan.
Hand over to a person (action "handoff") for complaints, damage, accidents, breakdowns, payments, refunds, insurance or legal questions, anything you are not sure about, or when the visitor asks for a person.
To start a booking request for the visitor, collect their full name, email and phone, the car and the dates, then call "start_request". Tell them a team member will send the offer by email.
Dates must be YYYY-MM-DD and times HH:MM (24 hours, default 10:00). Use today's date from the FACTS for words like tomorrow or this weekend.
Answer with one JSON object: {"action": "reply" | "search_cars" | "quote" | "start_request" | "handoff", "reply": "text for the visitor (for reply and handoff)", and the tool's fields: car (the slug), pickup_date, return_date, pickup_time, return_time, seats, class, name, email, phone, note, reason}.`;

function transcript(history: Turn[]): string {
  return history.slice(-12).map((t) => `${t.sender === 'visitor' ? 'Visitor' : t.sender === 'staff' ? 'Staff' : 'Assistant'}: ${t.body.replace(/\s+/g, ' ').slice(0, 600)}`).join('\n');
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^\d{2}:\d{2}$/;
const norm = (s: string) => s.toUpperCase().replace(/[^A-Z0-9]/g, '');
/** The car a visitor names by its car code (migration 0079), with or without the CC- and the dash, in any case. */
export function carByCode(f: Pick<ChatFacts, 'fleet'>, s?: string | null): FleetCar | undefined {
  if (!s) return undefined;
  const k = norm(s);
  if (k.length < 4) return undefined;
  return f.fleet.find((c) => c.code && (norm(c.code) === k || norm(c.code) === `CC${k}`));
}
/** Car codes written in a message (CC-7F3A, cc 7f3a); a car code always has a letter. */
export const codesIn = (text: string) => [...text.matchAll(/\bCC[\s-]?([A-Z0-9]{4,8})\b/gi)].map((m) => m[1]!.toUpperCase())
  .filter((c) => /[A-Z]/.test(c)).map((c) => `CC-${c}`); // a booking number (CC-10057) is digits only
const carBy = (f: ChatFacts, s?: string) => {
  if (!s) return undefined;
  const k = s.toLowerCase().trim();
  return f.fleet.find((c) => c.slug === k) ?? carByCode(f, s) ?? f.fleet.find((c) => c.name.toLowerCase().includes(k) || k.includes(c.name.toLowerCase().replace(/^\d{4} /, '')));
};

/** The amounts and percentages the assistant may repeat: the fleet's rates and deposits, the fees, and every amount
 *  a tool returned in this turn or earlier in the conversation (kept in each reply's meta). */
export function replyContext(f: ChatFacts, toolValues: unknown[], history: Turn[]): ReplyContext {
  const allowed = new Set<number>();
  for (const c of f.fleet) { allowed.add(c.daily_rate_cents); allowed.add(c.deposit_cents); if (c.weekly_rate_cents) allowed.add(c.weekly_rate_cents); }
  centsIn(f.rules.fees ?? {}, allowed);
  centsIn(f.rules.airports ?? [], allowed);
  for (const v of toolValues) centsIn(v, allowed);
  for (const t of history) if (t.meta && Array.isArray((t.meta as { cents?: unknown }).cents)) for (const n of (t.meta as { cents: number[] }).cents) allowed.add(n);
  const r = f.rules, c = r.cancellation ?? {};
  const percents = new Set<number>([5, 100]);
  for (const b of [r.non_refundable_discount_bps, r.hst_bps, c.early_bps, c.mid_bps, c.late_bps, c.grace_bps]) if (typeof b === 'number') percents.add(b / 100);
  return { allowedCents: allowed, allowedPercents: percents, neverSay: f.never_say ?? [] };
}

function quoteWords(car: FleetCar, q: QuoteResult, from: string, to: string): string {
  return `The ${car.name} from ${from} to ${to}: ${q.billable_days} days, ${money(q.total_cents ?? 0)} in total with HST, Deposit ${money(q.deposit_cents ?? 0)}${q.km_allowance_total ? `, ${q.km_allowance_total} km included` : ''}. Want me to start a booking request? I need your full name, email and phone.`;
}

export async function runAgent(deps: AgentDeps, input: AgentInput): Promise<AgentResult> {
  const meta: AgentResult['meta'] = { tools: [] };
  const why = escalationFor(input.text);
  if (why) return { ok: true, neurons: 0, handoff: { reason: ESCALATION_WORDS[why], escalation: why }, meta };

  const f = deps.facts;
  // a common question: answered from the facts, no model call
  const faq = faqReply(f, input.text);
  if (faq) {
    const c = checkReply(faq.reply, replyContext(f, [], input.history));
    if (c.ok) return { ok: true, neurons: 0, model: 'faq', reply: withContactAsk(c.text, input), meta: { ...meta, faq: faq.topic } };
  }
  const notes: string[] = [];
  const toolValues: unknown[] = [];
  let neurons = 0;
  let model: string | undefined;
  let lastQuote: { car: FleetCar; q: QuoteResult; from: string; to: string } | null = null;
  const known = [input.name && `name ${input.name}`, input.email && `email ${input.email}`, input.phone && `phone ${input.phone}`].filter(Boolean).join(', ');
  const last = input.history[input.history.length - 1];
  const history = last && last.sender === 'visitor' && last.body.trim() === input.text.trim() ? input.history : [...input.history, { sender: 'visitor' as const, body: input.text }];
  for (const code of codesIn(input.text)) {
    const c = carByCode(f, code);
    notes.push(c ? `The visitor wrote car code ${code}: that is ${c.slug} (${c.name}).` : `The visitor wrote car code ${code}: no car on the site has it. Ask them to check it.`);
  }
  const recent = [input.text, ...input.history.slice(-6).map((t) => t.body)].join(' ');
  const base = `FACTS:\n${factsText(f, { car: input.car, text: recent })}\n\nThe visitor is on: ${input.page ?? 'the site'}${input.car ? ` (car ${input.car})` : ''}.${known ? ` Known: ${known}.` : ''}\n\nCONVERSATION:\n${transcript(history)}`;

  for (let i = 0; i < 3; i++) {
    const prompt = `${base}${notes.length ? `\n\nTOOL RESULTS:\n${notes.join('\n')}` : ''}\n\nNext step (one JSON object):`;
    const r = await deps.model(SYSTEM, prompt);
    neurons += r.usage?.neurons ?? 0;
    if (!r.ok) return { ok: false, neurons, model, error: `${r.reason}: ${r.message}`, handoff: { reason: 'the assistant is not available' }, meta };
    model = r.model;
    const s = r.data;
    if (s.action === 'handoff') return { ok: true, neurons, model, handoff: { reason: (s.reason || 'the assistant handed over').slice(0, 200) }, meta };
    if (s.action === 'quote') {
      const car = carBy(f, s.car ?? input.car ?? undefined);
      const from = s.pickup_date ?? '', to = s.return_date ?? '';
      if (!car || !DATE.test(from) || !DATE.test(to)) { notes.push('quote: need a car from the list and both dates (YYYY-MM-DD). Ask the visitor.'); meta.tools.push({ name: 'quote', args: { car: s.car, from, to }, ok: false }); continue; }
      const tf = TIME.test(s.pickup_time ?? '') ? s.pickup_time! : '10:00', tt = TIME.test(s.return_time ?? '') ? s.return_time! : '10:00';
      const q = await deps.quote(car.vehicle_id, deps.instant(from, tf), deps.instant(to, tt));
      meta.tools.push({ name: 'quote', args: { car: car.slug, from, to, tf, tt }, ok: q.available });
      meta.car = car.slug;
      toolValues.push(q);
      if (!q.available) { notes.push(`quote ${car.slug} ${from} ${tf} to ${to} ${tt}: NOT available. ${(q.problems ?? []).map((p) => p.message).join(' ')}`); continue; }
      lastQuote = { car, q, from, to };
      meta.quote_total_cents = q.total_cents;
      notes.push(`quote ${car.slug} ${from} ${tf} to ${to} ${tt}: available, ${q.billable_days} days. ${(q.lines ?? []).map((l) => `${l.label} ${money(l.amount_cents)}`).join('; ')}. HST ${money(q.hst_cents ?? 0)}. Total ${money(q.total_cents ?? 0)}. Deposit ${money(q.deposit_cents ?? 0)}.${q.km_allowance_total ? ` ${q.km_allowance_total} km included.` : ''}`);
      continue;
    }
    if (s.action === 'search_cars') {
      const from = s.pickup_date ?? '', to = s.return_date ?? '';
      if (!DATE.test(from) || !DATE.test(to)) { notes.push('search_cars: need both dates (YYYY-MM-DD). Ask the visitor.'); continue; }
      const tf = TIME.test(s.pickup_time ?? '') ? s.pickup_time! : '10:00', tt = TIME.test(s.return_time ?? '') ? s.return_time! : '10:00';
      const filters: Record<string, unknown> = {};
      if (s.seats) filters.seats = s.seats;
      if (s.class) filters.class = s.class;
      const rows = await deps.search(deps.instant(from, tf), deps.instant(to, tt), filters);
      meta.tools.push({ name: 'search_cars', args: { from, to, ...filters }, ok: true });
      toolValues.push(rows);
      notes.push(rows.length ? `search_cars ${from} to ${to}: ${rows.slice(0, 6).map((x) => `${x.slug} (${x.vehicle_year} ${x.make} ${x.model}, ${x.seats} seats): ${money(x.total_cents)} total with HST for ${x.billable_days} days, Deposit ${money(x.deposit_cents)}`).join('; ')}${rows.length > 6 ? `; and ${rows.length - 6} more` : ''}.`
                              : `search_cars ${from} to ${to}: no car is free on those dates.`);
      continue;
    }
    if (s.action === 'start_request') {
      const car = carBy(f, s.car ?? input.car ?? undefined);
      const res = await deps.lead({ name: s.name ?? input.name ?? undefined, email: s.email ?? input.email ?? undefined, phone: s.phone ?? input.phone ?? undefined,
        car: car?.slug, pickup: s.pickup_date, return: s.return_date, note: s.note, quote_total_cents: lastQuote?.q.total_cents });
      meta.tools.push({ name: 'start_request', args: { car: car?.slug, pickup: s.pickup_date, return: s.return_date }, ok: res.ok });
      if (!res.ok) { notes.push(`start_request: missing ${res.missing ?? 'details'}. Ask the visitor for it.`); continue; }
      return { ok: true, neurons, model, meta, reply: tidy(`Thanks${s.name ? `, ${s.name.split(' ')[0]}` : ''}. Your request is with our team (reference ${res.reference}). A team member will check it and email you an offer. Nothing is booked until you approve the offer, sign and pay.`) };
    }
    // a reply: it must pass the rules, or it is replaced
    const ctx = replyContext(f, toolValues, input.history);
    const c = checkReply(s.reply ?? '', ctx);
    if (c.ok) {
      const cents = [...centsIn(toolValues)];
      return { ok: true, neurons, model, reply: withContactAsk(c.text, input), meta: { ...meta, ...(cents.length ? { cents } : {}) } };
    }
    meta.refused = [...(meta.refused ?? []), c.reason];
    if (lastQuote) {
      const cents = [...centsIn(toolValues)];
      return { ok: true, neurons, model, reply: quoteWords(lastQuote.car, lastQuote.q, lastQuote.from, lastQuote.to), meta: { ...meta, ...(cents.length ? { cents } : {}) } };
    }
    return { ok: true, neurons, model, meta, handoff: { reason: `the assistant could not answer safely (${c.reason})` } };
  }
  if (lastQuote) return { ok: true, neurons, model, meta, reply: quoteWords(lastQuote.car, lastQuote.q, lastQuote.from, lastQuote.to) };
  return { ok: true, neurons, model, meta, handoff: { reason: 'the assistant needed too many steps' } };
}
