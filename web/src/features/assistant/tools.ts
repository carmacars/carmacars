// The staff assistant's tools (migration 0080): what it may read and what it may propose, per portal and function, with
// the arguments each takes (checked here before anything reaches the database) and the card text a change shows before
// Confirm. Pure: the unit tests and the server use the same definitions. Every change runs through the same door
// function as the screen (app.assistant_action_door in the database holds the same list).
import { z } from 'zod';

export type Portal = 'admin' | 'va' | 'field';
export type VaFn = 'cs' | 'fleet' | 'finance' | 'sales';
export interface Who { portal: Portal; fn?: VaFn | null }

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'a date like 2026-10-15');
const dateTime = z.string().regex(/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/, 'a date and time like 2026-10-22 10:00');
const text = (min: number, max: number) => z.string().trim().min(min).max(max);
const dollars = z.coerce.number().positive('an amount above $0').max(1_000_000);

export const METHODS = ['e_transfer', 'cheque', 'cash', 'bank_transfer', 'other'] as const;
export const METHOD_WORDS: Record<(typeof METHODS)[number], string> = { e_transfer: 'e-Transfer', cheque: 'cheque', cash: 'cash', bank_transfer: 'bank transfer', other: 'payment' };
/** How the rental of an offer is paid (0129): card online, or another way that staff confirm when the money is in. */
export const RENTAL_PAY = ['card', 'e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout', 'insurer'] as const;
export const DEPOSIT_PAY = ['card', 'cash', 'e_transfer'] as const;
export const PAY_WORDS: Record<string, string> = { card: 'card', e_transfer: 'e-Transfer', cash: 'cash', cheque: 'cheque', bank_transfer: 'bank transfer', platform_payout: 'platform payout', insurer: 'the insurer', other: 'another way' };
export const COVERS = ['rental', 'deposit', 'fees', 'later'] as const;
/** The customer of a rental or an offer: one on file (a name, email or phone), or a new one with their details. */
const customerFields = {
  customer: text(2, 120).optional(),
  renter_name: text(3, 120).optional(), renter_email: z.string().trim().email('the renter\'s email').optional(), renter_mobile: text(7, 30).optional(),
  renter_date_of_birth: date.optional()
};
/** The price said in words (2026-10-27): the rental charge, the Protection Plan, either typed after tax ("$270 after tax"),
 *  or the total the customer pays with HST ("$320 total after tax"), from which the rental charge is worked out. */
const priceFields = {
  rental_total: dollars.optional(), price_reason: text(3, 200).optional(), coverage: z.coerce.number().int().min(1).max(3).optional(),
  tax_included: z.boolean().optional(), total_after_tax: dollars.optional(), plan_price: dollars.optional()
};
const PRICE_ARGS = '"rental_total"?: dollars, "tax_included"?: true if after tax, "total_after_tax"?: dollars with HST, "plan_price"?: dollars, "price_reason"?, "coverage"?: 1|2|3';
const priceRule = (a: { rental_total?: number; total_after_tax?: number }) => a.rental_total === undefined || a.total_after_tax === undefined;
const PRICE_PROBLEM = { message: 'either the rental price or the total after tax, not both', path: ['total_after_tax'] };
const hasCustomer = (a: { customer?: string; renter_name?: string; renter_email?: string; renter_mobile?: string }) => !!a.customer || (!!a.renter_name && !!a.renter_email && !!a.renter_mobile);
const CUSTOMER_PROBLEM = { message: 'the customer: a name, email or phone of one on file, or a new customer\'s name, email and mobile' };

export const SCHEMAS = {
  // reads
  today: z.object({}).strict(),
  find: z.object({ kind: z.enum(['booking', 'renter', 'owner', 'car', 'invoice', 'toll']), q: text(1, 80) }).strict(),
  availability: z.object({ pickup_date: date, return_date: date, car: text(2, 80).optional() }).strict(),
  who_has_car: z.object({ car: text(2, 80) }).strict(),
  owner_balance: z.object({ owner: text(2, 80) }).strict(),
  draft_message: z.object({ to: z.enum(['renter', 'owner']), name: text(2, 80), text: text(10, 1500), booking: text(3, 30).optional() }).strict(),
  // changes (a card first, then Confirm)
  record_payment: z.object({
    invoice: text(3, 30).optional(), booking: text(3, 30).optional(), amount: dollars.optional(), method: z.enum(METHODS),
    reference: text(3, 60).optional(), received_on: date, note: text(2, 300).optional(), covers: z.enum(COVERS).optional()
  }).strict().refine((a) => !!a.invoice !== !!a.booking, { message: 'name the invoice or the booking (one of them)' })
    .refine((a) => !['e_transfer', 'cheque', 'bank_transfer'].includes(a.method) || !!a.reference, { message: 'the reference number of the payment', path: ['reference'] })
    .refine((a) => a.method !== 'other' || !!a.note, { message: 'how it was paid, in the note', path: ['note'] }),
  add_rental: z.object({
    car: text(2, 80), pickup_at: dateTime, return_at: dateTime, ...customerFields, licence_number: text(5, 40).optional(),
    payment: z.enum(['link', 'other_way']).default('link'), method: z.enum(METHODS).optional(), reference: text(3, 60).optional(), amount: dollars.optional(),
    deposit_method: z.enum(DEPOSIT_PAY).optional(), agreement: z.enum(['send', 'paper']).optional(),
    sourced_by_me: z.boolean().default(false), note: text(2, 300).optional(), ...priceFields
  }).strict().refine((a) => a.payment !== 'other_way' || !!a.method, { message: 'how the rental was paid', path: ['method'] }).refine(hasCustomer, CUSTOMER_PROBLEM).refine(priceRule, PRICE_PROBLEM),
  create_offer: z.object({
    car: text(2, 80), pickup_at: dateTime, return_at: dateTime, ...customerFields, ...priceFields,
    rental_pay: z.enum(RENTAL_PAY).default('card'), deposit_pay: z.enum(DEPOSIT_PAY).default('card'),
    notify: z.enum(['email', 'text', 'both', 'none']).default('email'), message: text(2, 600).optional(), expires_hours: z.coerce.number().int().min(1).max(168).optional(),
    sourced_by_me: z.boolean().default(false)
  }).strict().refine(hasCustomer, CUSTOMER_PROBLEM).refine((a) => a.rental_total === undefined || !!a.price_reason, { message: 'why the rental price differs from the rates', path: ['price_reason'] }).refine(priceRule, PRICE_PROBLEM),
  booking_balance: z.object({ booking: text(3, 30).optional(), customer: text(2, 120).optional() }).strict()
    .refine((a) => !!a.booking !== !!a.customer, { message: 'name the booking or the customer (one of them)' }),
  publish_car: z.object({ car: text(2, 80) }).strict(),
  mark_insured: z.object({ car: text(2, 80), on: date.optional(), reference: text(2, 200).optional() }).strict(),
  set_rates: z.object({ car: text(2, 80), daily: dollars, weekend: dollars.optional(), weekly: dollars.optional(), monthly: dollars.optional() }).strict(),
  send_payment_link: z.object({ booking: text(3, 30).optional(), invoice: text(3, 30).optional() }).strict()
    .refine((a) => !!a.invoice !== !!a.booking, { message: 'name the booking or the owner invoice (one of them)' }),
  confirm_toll: z.object({ toll: text(3, 60) }).strict(),
  create_task: z.object({ title: text(3, 200), detail: text(2, 2000).optional(), queue: z.enum(['finance', 'fleet', 'cs', 'sales', 'admin']).optional(),
    due: dateTime.optional(), priority: z.enum(['low', 'normal', 'high', 'urgent']).optional(), booking: text(3, 30).optional() }).strict()
} as const;
export type ToolName = keyof typeof SCHEMAS;
export type Args<T extends ToolName> = z.infer<(typeof SCHEMAS)[T]>;

export interface ToolDef { name: ToolName; change: boolean; about: string; args: string }
export const TOOLS: Record<ToolName, ToolDef> = {
  today: { name: 'today', change: false, about: 'What needs doing today (To do, my tasks, pickups and returns)', args: '{}' },
  find: { name: 'find', change: false, about: 'Find a booking, renter, owner, car, owner invoice or toll notice', args: '{"kind": "booking|renter|owner|car|invoice|toll", "q": "words, a number, a plate or a car code (CC-7F3A)"}' },
  availability: { name: 'availability', change: false, about: 'Which cars are free for dates, or whether one car is', args: '{"pickup_date": "YYYY-MM-DD", "return_date": "YYYY-MM-DD", "car"?: "name or plate"}' },
  who_has_car: { name: 'who_has_car', change: false, about: 'Who has a car right now and when it is due back', args: '{"car": "name or plate"}' },
  booking_balance: { name: 'booking_balance', change: false, about: 'What a renter owes on a booking: the rental, fees and later charges still open, and the deposit', args: '{"booking"?: "number", "customer"?: "renter name, email or phone"}' },
  owner_balance: { name: 'owner_balance', change: false, about: 'An owner\'s open invoices and what they owe', args: '{"owner": "name"}' },
  draft_message: { name: 'draft_message', change: false, about: 'Write a message for a renter or owner; staff send it themselves', args: '{"to": "renter|owner", "name": "who", "text": "the message", "booking"?: "number"}' },
  record_payment: { name: 'record_payment', change: true, about: 'Record a payment received another way (e-Transfer, cheque, cash, bank transfer) on an owner invoice or a booking', args: '{"invoice"?: "INV-...", "booking"?: "number", "covers"?: "rental|deposit|fees|later" (a booking: which part; default rental), "amount"?: dollars (empty: what is open), "method": "e_transfer|cheque|cash|bank_transfer|other", "reference"?: "number", "received_on": "YYYY-MM-DD", "note"?: "text"}' },
  add_rental: { name: 'add_rental', change: true, about: 'Add a rental by hand (phone, counter, already underway): it is booked at once', args: '{"car": "name or plate", "pickup_at": "YYYY-MM-DD HH:MM", "return_at": "YYYY-MM-DD HH:MM", "customer"?: "name, email or phone on file" | "renter_name", "renter_email", "renter_mobile", "renter_date_of_birth"?, "licence_number"?, "payment": "link|other_way", "method"?, "reference"?, "amount"?: dollars paid, "deposit_method"?: "card|cash|e_transfer", "agreement"?: "send|paper", "sourced_by_me"?: true|false, ' + PRICE_ARGS + '}' },
  create_offer: { name: 'create_offer', change: true, about: 'Make an offer and send it to the customer to sign and pay (no request needed)', args: '{"car": "name or plate", "pickup_at": "YYYY-MM-DD HH:MM", "return_at": "YYYY-MM-DD HH:MM", "customer"?: "name, email or phone on file" | "renter_name", "renter_email", "renter_mobile", "renter_date_of_birth": "YYYY-MM-DD", ' + PRICE_ARGS + ', "rental_pay"?: "card|e_transfer|cash|cheque|bank_transfer|platform_payout|insurer", "deposit_pay"?: "card|cash|e_transfer", "notify"?: "email|text|both|none", "message"?, "expires_hours"?, "sourced_by_me"?: true|false (the staff member found this client)}' },
  publish_car: { name: 'publish_car', change: true, about: 'Publish a car on the website', args: '{"car": "name or plate"}' },
  mark_insured: { name: 'mark_insured', change: true, about: 'Mark a car insured: the insurer confirmed in writing that it is on the fleet policy', args: '{"car": "name, plate or car code", "on"?: "YYYY-MM-DD, the date of the insurer\'s email (empty: today)", "reference"?: "the email\'s subject"}' },
  set_rates: { name: 'set_rates', change: true, about: 'Set a car\'s rates in dollars (weekend, weekly, monthly optional)', args: '{"car": "name or plate", "daily": dollars, "weekend"?, "weekly"?, "monthly"?}' },
  send_payment_link: { name: 'send_payment_link', change: true, about: 'Send the payment link again: a booking\'s offer (sign and pay) or an owner invoice', args: '{"booking"?: "number", "invoice"?: "INV-..."}' },
  confirm_toll: { name: 'confirm_toll', change: true, about: 'Confirm the suggested match of a toll or ticket notice', args: '{"toll": "notice number"}' },
  create_task: { name: 'create_task', change: true, about: 'Add a task to a queue', args: '{"title": "text", "detail"?, "queue"?: "finance|fleet|cs|sales|admin", "due"?: "YYYY-MM-DD HH:MM", "priority"?: "low|normal|high|urgent", "booking"?: "number"}' }
};

/** The tools a person sees in their portal: only these go into the request (a short prompt saves neurons). The
 *  database checks each again, so this list is for focus, not for safety. */
export function toolsFor(w: Who): ToolName[] {
  if (w.portal === 'admin') return Object.keys(TOOLS) as ToolName[];
  if (w.portal === 'field') return ['today', 'find', 'availability', 'who_has_car', 'add_rental'];
  const common: ToolName[] = ['today', 'find', 'create_task', 'draft_message'];
  switch (w.fn) {
    case 'finance': return [...common, 'owner_balance', 'booking_balance', 'record_payment', 'send_payment_link', 'confirm_toll'];
    case 'fleet': return [...common, 'availability', 'who_has_car', 'publish_car', 'mark_insured', 'set_rates', 'add_rental'];
    case 'cs': return [...common, 'availability', 'who_has_car', 'create_offer', 'add_rental', 'booking_balance', 'record_payment', 'send_payment_link', 'publish_car'];
    case 'sales': return [...common, 'availability', 'create_offer', 'add_rental', 'booking_balance', 'send_payment_link'];
    default: return common;
  }
}

/** Checks a tool's arguments: the parsed values, or what is missing in plain words. */
export function checkArgs<T extends ToolName>(name: T, raw: unknown): { ok: true; args: Args<T> } | { ok: false; problem: string } {
  const schema = SCHEMAS[name] as unknown as z.ZodType<Args<T>>;
  if (!schema) return { ok: false, problem: `unknown tool ${String(name)}` };
  const r = schema.safeParse(raw ?? {});
  if (r.success) return { ok: true, args: r.data };
  const parts = r.error.issues.map((i) => {
    const where = i.path.length ? String(i.path[0]).replace(/_/g, ' ') : '';
    if (i.code === 'unrecognized_keys') return `remove ${(i as unknown as { keys: string[] }).keys.join(', ')}`;
    if (i.code === 'invalid_type' && i.input === undefined) return where ? `the ${where}` : i.message;
    return where && !i.message.startsWith('the') ? `${where}: ${i.message}` : i.message;
  });
  return { ok: false, problem: [...new Set(parts)].join('; ') };
}

/** JSON schemas of a portal's tools, for a model with native tool calling (Claude). */
export function jsonSchemas(names: ToolName[]): Array<{ name: string; description: string; input_schema: Record<string, unknown> }> {
  return names.map((n) => {
    let s: Record<string, unknown> = { type: 'object', properties: {} };
    try { s = z.toJSONSchema(SCHEMAS[n] as unknown as z.ZodType, { unrepresentable: 'any' }) as Record<string, unknown>; } catch { /* the plain object */ }
    delete s.$schema;
    return { name: n, description: `${TOOLS[n].about}${TOOLS[n].change ? ' (shows a card; runs only after the staff member confirms)' : ''}`, input_schema: s };
  });
}

// ---------------------------------------------------------------- the card text of a change
const money = (dollarsValue: number) => `$${dollarsValue.toLocaleString('en-CA', { minimumFractionDigits: dollarsValue % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export function shortDate(d: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(d);
  if (!m) return d;
  const base = `${MONTHS[Number(m[2]) - 1]} ${Number(m[3])}`;
  if (!m[4]) return base;
  const h = Number(m[4]), mm = m[5];
  return `${base}, ${h === 0 ? 12 : h > 12 ? h - 12 : h}:${mm} ${h < 12 ? 'am' : 'pm'}`;
}
export const cents = (d: number | undefined) => (d === undefined ? undefined : Math.round(d * 100));

/** What the confirmation card says, with the names the database found (invoice owner, car name, renter). */
export function summary(name: ToolName, a: Record<string, unknown>, k: Record<string, string | undefined> = {}): string {
  switch (name) {
    case 'record_payment': {
      const what = METHOD_WORDS[a.method as (typeof METHODS)[number]] ?? 'payment';
      const amount = a.amount ? `a ${money(Number(a.amount))} ${what}` : `the balance${k.balance ? ` (${k.balance})` : ''} as an ${what}`.replace('as an c', 'as a c');
      const part = a.booking && a.covers && a.covers !== 'rental' ? ` (${a.covers === 'later' ? 'later charges' : String(a.covers)})` : '';
      const on = a.invoice ? `${String(a.invoice).toUpperCase()}${k.owner ? ` for ${k.owner}` : ''}` : `booking ${String(a.booking)}${k.renter ? ` for ${k.renter}` : ''}${part}`;
      return `Record ${amount} on ${on}, dated ${shortDate(String(a.received_on))}${a.reference ? `, reference ${String(a.reference)}` : ''}?`;
    }
    case 'create_offer':
      return `Send an offer for the ${k.car ?? String(a.car)} to ${k.customer ?? String(a.renter_name ?? a.customer)}, ${shortDate(String(a.pickup_at))} to ${shortDate(String(a.return_at))}${k.due ? `: ${k.due} due at booking` : ''}${a.notify === 'none' ? ', without telling the customer' : `, by ${a.notify === 'both' ? 'email and text' : String(a.notify ?? 'email')}`}?`;
    case 'add_rental':
      return `Add a rental of the ${k.car ?? String(a.car)} for ${k.customer ?? String(a.renter_name ?? a.customer)}, ${shortDate(String(a.pickup_at))} to ${shortDate(String(a.return_at))}, ${a.payment === 'other_way' ? `paid by ${METHOD_WORDS[a.method as (typeof METHODS)[number]] ?? 'another way'}${a.amount ? ` (${money(Number(a.amount))})` : ''}` : 'with a payment link emailed to the renter'}${k.phase === 'in_progress' ? ' (already underway: recorded on trip)' : ''}?`;
    case 'publish_car': return `Publish the ${k.car ?? String(a.car)} on the website now?`;
    case 'mark_insured':
      return `Mark the ${k.car ?? String(a.car)} insured: the insurer confirmed in writing on ${shortDate(String(a.on ?? k.today ?? ''))} that it is on the fleet policy${a.reference ? ` (${String(a.reference)})` : ''}?`;
    case 'set_rates':
      return `Set the rates of the ${k.car ?? String(a.car)}: ${money(Number(a.daily))} a day${a.weekend ? `, ${money(Number(a.weekend))} a weekend day` : ''}${a.weekly ? `, ${money(Number(a.weekly))} a week` : ''}${a.monthly ? `, ${money(Number(a.monthly))} a month` : ''}?`;
    case 'send_payment_link':
      return a.booking ? `Send booking ${String(a.booking)}${k.renter ? ` (${k.renter})` : ''} its offer again, with the link to sign and pay?` : `Email invoice ${String(a.invoice).toUpperCase()}${k.owner ? ` to ${k.owner}` : ''} again, with its payment link?`;
    case 'confirm_toll': return `Confirm the match of notice ${String(a.toll)}${k.match ? ` to ${k.match}` : ''}?`;
    case 'create_task':
      return `Add the task "${String(a.title)}" to the ${String(a.queue ?? 'admin')} queue${a.due ? `, due ${shortDate(String(a.due))}` : ''}${a.priority && a.priority !== 'normal' ? `, ${String(a.priority)} priority` : ''}?`;
    default: return `Run ${name}?`;
  }
}
