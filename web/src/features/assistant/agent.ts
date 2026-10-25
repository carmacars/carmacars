// The staff assistant (migration 0080): one question in, a short answer out. The model picks one step (a reply, a
// question, or a tool with its arguments, as JSON); a read runs at once and its result is the answer (no second model
// call, to save neurons); a change is checked, its names are looked up in the database, and it comes back as a card
// that runs only after Confirm. Pure: every outside service is passed in (src/server/assistant.ts wires the real
// ones), so the unit tests run it with a stub model.
import { checkArgs, cents, PAY_WORDS, shortDate, summary, TOOLS, toolsFor, type Portal, type ToolName, type Who } from './tools.ts';
import { pauseMessage } from '../usage/model.ts';
import { torontoInstant } from '../../lib/dates.ts';

export interface Turn { role: 'user' | 'assistant'; text: string }
export interface Step { action: 'reply' | 'tool' | 'ask'; reply?: string; tool?: string; args?: Record<string, unknown>; question?: string; options?: string[] }
export interface Row { title: string; sub?: string; href?: string }
/** A card's details (0133): sections of label and value rows, shown under the summary before Confirm. */
export type Details = Array<{ title: string; rows: Array<{ label: string; value: string }> }>;
export type Out =
  | { type: 'text'; text: string }
  | { type: 'results'; title: string; rows: Row[]; empty?: string }
  | { type: 'proposal'; id: string; summary: string; details?: Details }
  | { type: 'question'; text: string; options: string[] }
  | { type: 'draft'; to: 'renter' | 'owner'; name: string; text: string; href: string }
  | { type: 'paused'; text: string };

export const STEP_SCHEMA = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: ['reply', 'tool', 'ask'] },
    reply: { type: 'string' },
    tool: { type: 'string' },
    args: { type: 'object' },
    question: { type: 'string' },
    options: { type: 'array', items: { type: 'string' } }
  },
  required: ['action']
} as const;

export interface ModelUsage { units: number; unit: 'neurons' | 'microusd' }
export type ModelResult = { ok: true; step: Step; usage: ModelUsage; model: string } | { ok: false; reason: 'quota' | 'unavailable' | 'timeout' | 'invalid_output'; message: string; usage?: ModelUsage; model?: string };
export interface AssistantModel {
  readonly name: 'workers-ai' | 'claude' | 'fake';
  readonly service: 'workers_ai' | 'claude';
  step(system: string, turns: Turn[], tools: ToolName[]): Promise<ModelResult>;
}

export interface FindRow { [k: string]: unknown }
export interface Deps {
  who: Who;
  /** Toronto's date today (YYYY-MM-DD) and the person's first name. */
  today: string; name?: string | null;
  model: AssistantModel;
  gate(): Promise<{ ok: boolean; service?: string } & Record<string, unknown>>;
  record(u: ModelUsage & { ok: boolean; model?: string; error?: string; ms: number }): Promise<void>;
  todo(): Promise<Out[]>;
  find(kind: 'booking' | 'renter' | 'owner' | 'car' | 'invoice' | 'toll' | 'car_now' | 'owner_balance', q: string): Promise<FindRow[]>;
  available(from: string, to: string): Promise<FindRow[]>;
  /** The staff screens' reads (0129), as the person: the offer preview (priced, rolled back), the offer form (every car
   *  with whether it is free), the customer search and a booking's money. Absent: the assistant works without them. */
  staff?(what: 'offer_preview' | 'offer_form' | 'find_customers' | 'booking_money', p: Record<string, unknown>): Promise<Record<string, unknown>>;
  propose(p: { tool: ToolName; name: string; args: Record<string, unknown>; summary: string; details?: Details }): Promise<{ id: string; summary: string; details?: Details }>;
  now?(): number;
}

export const HISTORY_TURNS = 6;
const base = (p: Portal) => `/${p}`;

/** The system prompt: short, with only this person's tools. */
export function systemPrompt(who: Who, today: string, tools: ToolName[]): string {
  const role = who.portal === 'admin' ? 'an Admin' : who.portal === 'field' ? 'field staff' : `an assistant (${who.fn ?? 'staff'})`;
  return [
    `You are the CarmaCars staff assistant, helping ${role}. Today is ${today} (Toronto). Answer in one or two short sentences.`,
    'Use a tool for facts: never invent bookings, cars, people, amounts or dates. Changes are only proposed: the staff member confirms a card before anything runs.',
    'If a detail is missing or more than one thing matches, ask (action "ask") and list the choices in "options".',
    'Amounts are in dollars. Dates YYYY-MM-DD; times HH:MM, 24 hours, Toronto. A car is marked insured only when the insurer confirmed it in writing.',
    'Tools:',
    ...tools.map((t) => `- ${t}: ${TOOLS[t].about}. args ${TOOLS[t].args}`),
    'Answer with one JSON object: {"action": "reply" | "tool" | "ask", "reply": "text", "tool": "name", "args": {...}, "question": "text", "options": ["..."]}.'
  ].join('\n');
}

const money = (c: unknown) => (c === null || c === undefined ? '' : `$${(Number(c) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
const when = (iso: unknown) => (typeof iso === 'string' ? iso.replace('T', ' ').slice(0, 16) : '');
const norm = (s: string) => s.toUpperCase().replace(/[^A-Z0-9]/g, '');

/** Amounts typed as text ("$900", "1,250.50") become numbers before the arguments are checked. */
export function tidyArgs(a: Record<string, unknown> | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(a ?? {})) {
    if (v === null || v === '') continue;
    out[k] = typeof v === 'string' && ['amount', 'daily', 'weekend', 'weekly', 'monthly'].includes(k) ? v.replace(/[$,\s]/g, '') : v;
  }
  return out;
}

type Pick1 = { row: FindRow } | { out: Out };
/** One row for a name, or the question that lists the candidates. */
async function one(d: Deps, kind: Parameters<Deps['find']>[0], q: string, what: string, label: (r: FindRow) => string, exact?: (r: FindRow) => boolean): Promise<Pick1> {
  const rows = await d.find(kind, q);
  if (!rows.length) return { out: { type: 'question', text: `I could not find ${what} matching "${q}". Which one do you mean?`, options: [] } };
  const ex = exact ? rows.filter(exact) : [];
  if (rows.length === 1) return { row: rows[0]! };
  if (ex.length === 1) return { row: ex[0]! };
  return { out: { type: 'question', text: `More than one ${what} matches "${q}". Which one?`, options: rows.slice(0, 6).map(label) } };
}
const carLabel = (r: FindRow) => `${String(r.name ?? r.car)}${r.plate ? ` (${String(r.plate)})` : ''}${r.sample ? ' (example car)' : ''}`;
const carExact = (q: string) => (r: FindRow) => norm(String(r.plate ?? '')) === norm(q) || norm(String(r.fleet_number ?? '')) === norm(q) || norm(String(r.name ?? '')) === norm(q)
  || (!!r.car_code && [norm(q), `CC${norm(q)}`].includes(norm(String(r.car_code))));

/** A local "YYYY-MM-DD HH:MM" as an instant. */
export const instant = (s: string) => torontoInstant(s.slice(0, 10), s.slice(11, 16));

/** Runs a read tool: its result as cards. */
async function read(d: Deps, tool: ToolName, a: Record<string, unknown>): Promise<Out[]> {
  const b = base(d.who.portal);
  switch (tool) {
    case 'today': return d.todo();
    case 'find': {
      const rows = await d.find(a.kind as 'booking', String(a.q));
      const map: Record<string, (r: FindRow) => Row> = {
        booking: (r) => ({ title: `${String(r.booking_number)} · ${String(r.status).replace(/_/g, ' ')}`, sub: [r.renter, r.car, `${when(r.pickup_at)} to ${when(r.return_at)}`].filter(Boolean).join(' · '), href: d.who.portal === 'field' ? undefined : `${b}/bookings/${String(r.booking_number)}` }),
        renter: (r) => ({ title: String(r.name), sub: [r.email, r.mobile, `${String(r.bookings)} bookings`].filter(Boolean).join(' · '), href: d.who.portal === 'admin' ? `/admin/renters?q=${encodeURIComponent(String(r.email ?? r.name))}` : undefined }),
        owner: (r) => ({ title: String(r.name), sub: [r.status, r.email, r.phone, `${String(r.cars)} cars`].filter(Boolean).join(' · '), href: d.who.portal === 'admin' ? `/admin/owners/${String(r.id)}` : undefined }),
        car: (r) => ({ title: `${String(r.name)}${r.sample ? ' (example car)' : ''}`, sub: [r.plate && `plate ${String(r.plate)}`, r.car_code && String(r.car_code), String(r.status).replace(/_/g, ' '), r.listing && `listing ${String(r.listing)}`].filter(Boolean).join(' · '), href: d.who.portal === 'field' ? undefined : `${b}/vehicles/${String(r.id)}` }),
        invoice: (r) => ({ title: `${String(r.invoice_number)} · ${String(r.owner)}`, sub: `${String(r.status).replace(/_/g, ' ')} · total ${money(r.total_cents)} · balance ${money(r.balance_cents)}${r.due_on ? ` · due ${String(r.due_on)}` : ''}`, href: d.who.portal === 'admin' ? `/admin/invoices/${String(r.invoice_number)}` : undefined }),
        toll: (r) => ({ title: `${String(r.notice_number ?? 'Notice')} · ${String(r.authority ?? r.kind)}`, sub: `plate ${String(r.plate ?? '')} · ${when(r.occurred_at)} · ${money(r.amount_cents)}${r.booking_number ? ` · suggested: ${String(r.booking_number)}` : ' · no suggested match'}` })
      };
      return [{ type: 'results', title: `${String(a.kind).replace(/^./, (c) => c.toUpperCase())} matching "${String(a.q)}"`, rows: rows.map(map[String(a.kind)]!), empty: 'Nothing matches. Try a number, a plate or another spelling.' }];
    }
    case 'availability': {
      const staffCars = await staffAvailability(d, a);
      if (staffCars) return staffCars;
      const rows = await d.available(String(a.pickup_date), String(a.return_date));
      const label = (r: FindRow) => [r.vehicle_year, r.make, r.model].filter(Boolean).join(' ');
      if (a.car) {
        const q = String(a.car).toLowerCase();
        const hit = rows.filter((r) => label(r).toLowerCase().includes(q) || String(r.slug ?? '').includes(q.replace(/\s+/g, '-')));
        return [{ type: 'text', text: hit.length ? `Yes: ${hit.map((r) => `the ${label(r)} is free from ${String(a.pickup_date)} to ${String(a.return_date)} (${money(r.total_cents)} with HST)`).join('; ')}.`
          : `No car matching "${String(a.car)}" is free from ${String(a.pickup_date)} to ${String(a.return_date)}. ${rows.length} other car${rows.length === 1 ? ' is' : 's are'} free.` }];
      }
      return [{ type: 'results', title: `Free from ${String(a.pickup_date)} to ${String(a.return_date)}`, rows: rows.slice(0, 12).map((r) => ({ title: label(r), sub: `${String(r.vehicle_class ?? '')} · ${money(r.daily_rate_cents)} a day · ${money(r.total_cents)} with HST`, href: r.slug ? `/cars/${String(r.slug)}` : undefined })), empty: 'No car is free on those dates.' }];
    }
    case 'who_has_car': {
      const rows = await d.find('car_now', String(a.car));
      return [{ type: 'results', title: `Who has "${String(a.car)}" now`, empty: 'No car matches.', rows: rows.map((r) => ({ title: `${String(r.car)}${r.plate ? ` (${String(r.plate)})` : ''}`,
        sub: r.booking_number ? `${String(r.renter ?? 'A renter')} has it on ${String(r.booking_number)}${r.renter_mobile ? `, ${String(r.renter_mobile)}` : ''}, due back ${when(r.due_back)}${r.late ? ' (late)' : ''}` : `Nobody: the car is ${String(r.car_status).replace(/_/g, ' ')}` })) }];
    }
    case 'owner_balance': {
      const rows = await d.find('owner_balance', String(a.owner));
      return [{ type: 'results', title: `Balance of "${String(a.owner)}"`, empty: 'No owner matches.', rows: rows.map((r) => ({ title: `${String(r.owner)}: ${money(r.balance_cents)} owing`,
        sub: ((r.open_invoices as FindRow[]) ?? []).map((i) => `${String(i.invoice_number)} ${money(i.balance_cents)} (${String(i.status).replace(/_/g, ' ')}${i.due_on ? `, due ${String(i.due_on)}` : ''})`).join(' · ') || 'No open invoices',
        href: d.who.portal === 'admin' ? `/admin/owners/${String(r.owner_id)}` : undefined })) }];
    }
    case 'booking_balance': return bookingBalance(d, a);
    case 'draft_message': {
      const href = d.who.portal === 'admin' ? (a.booking ? `/admin/bookings/${String(a.booking)}` : '/admin/messages') : d.who.portal === 'va' ? (a.booking ? `/va/bookings/${String(a.booking)}` : '/va/messages') : '/field';
      return [{ type: 'draft', to: a.to as 'renter', name: String(a.name), text: String(a.text), href }];
    }
    default: return [];
  }
}

const dollars = (v: number) => `$${v.toLocaleString('en-CA', { minimumFractionDigits: v % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
const ACTIVE = ['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent', 'returned'];

/** The customer of a rental or an offer: one on file by name, email or phone (the offer screen's search), else the new
 *  customer's details as typed. More than one match: the question with the choices. */
async function customerFor(d: Deps, a: Record<string, unknown>): Promise<{ renterId?: string; name: string; label: string; dob?: string } | { out: Out }> {
  const q = String(a.customer ?? a.renter_email ?? '').trim();
  if (q && d.staff) {
    const rows = (await d.staff('find_customers', { q }).catch(() => [])) as unknown as FindRow[];
    const list = Array.isArray(rows) ? rows : [];
    const exact = list.filter((r) => [r.email, r.mobile, r.legal_name].some((v) => String(v ?? '').toLowerCase() === q.toLowerCase()));
    const pick = list.length === 1 ? list[0] : exact.length === 1 ? exact[0] : null;
    if (pick) {
      if (pick.is_blocked) return { out: { type: 'text', text: `${String(pick.legal_name)} is blocked from renting: an Admin must lift the block first. Nothing was prepared.` } };
      return { renterId: String(pick.id), name: String(pick.legal_name), label: [pick.legal_name, pick.email, pick.mobile].filter(Boolean).join(' · ') + ' (on file)', dob: pick.date_of_birth ? String(pick.date_of_birth) : undefined };
    }
    if (list.length > 1) return { out: { type: 'question', text: `More than one customer matches "${q}". Which one?`, options: list.slice(0, 6).map((r) => [r.legal_name, r.email ?? r.mobile].filter(Boolean).join(', ')) } };
    if (a.customer && !a.renter_name) return { out: { type: 'question', text: `No customer on file matches "${q}". What are the new customer's full name, email, mobile and date of birth?`, options: [] } };
  }
  if (!a.renter_name || !a.renter_email || !a.renter_mobile) return { out: { type: 'question', text: 'Who is the customer? A name, email or phone on file, or a new customer\'s full name, email and mobile.', options: [] } };
  return { name: String(a.renter_name), label: `${String(a.renter_name)} · ${String(a.renter_email)} · ${String(a.renter_mobile)} (new customer)` };
}

type Priced = { ok: true; available?: boolean; booking: { billable_days?: number; deposit_cents: number; hst_at_booking_cents?: number; total_due_at_booking_cents: number; renter_due_at_booking_cents?: number | null;
  lines?: Array<{ charge_type: string; description: string | null; amount_cents: number; hst_cents?: number; stage?: string; charged_to_renter?: boolean }> } } | { ok: false; error: string };
/** The offer screen's preview (0129): the booking made, priced and rolled back. */
async function preview(d: Deps, p: Record<string, unknown>): Promise<Priced> {
  if (!d.staff) return { ok: false, error: 'the price preview is not available here' };
  try {
    const r = await d.staff('offer_preview', p) as { ok?: boolean; error?: string; booking?: Extract<Priced, { ok: true }>['booking']; available?: boolean };
    if (!r.ok || !r.booking) return { ok: false, error: String(r.error ?? 'the database refused it').replace(/^.*?ERROR:\s*/, '') };
    return { ok: true, available: r.available, booking: r.booking };
  } catch (e) { return { ok: false, error: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'the database refused it' }; }
}
/** The price lines of a preview, for the card: each line before tax, the HST, what is due at booking, the deposit. */
function priceSection(p: Priced): Details[number] {
  if (!p.ok) return { title: 'Price', rows: [{ label: 'Price', value: `Worked out from the car's rates when it is added (no preview: ${p.error})` }] };
  const b = p.booking;
  const lines = (b.lines ?? []).filter((l) => l.charged_to_renter !== false && (l.stage ?? 'booking') === 'booking' && l.amount_cents !== 0);
  return { title: 'Price', rows: [
    ...lines.map((l) => ({ label: l.description || l.charge_type.replace(/_/g, ' ').replace(/^./, (x) => x.toUpperCase()), value: money(l.amount_cents) })),
    ...(b.hst_at_booking_cents ? [{ label: 'HST', value: money(b.hst_at_booking_cents) }] : []),
    { label: 'Due at booking', value: money(b.renter_due_at_booking_cents ?? b.total_due_at_booking_cents) },
    { label: 'Deposit (refundable)', value: money(b.deposit_cents) }] };
}

/** Every car with whether it is free (the offer screen's list, 0129: unpublished cars too, with their rates). Null when
 *  the person may not use the offer screen (field staff): the public search answers then. */
async function staffAvailability(d: Deps, a: Record<string, unknown>): Promise<Out[] | null> {
  if (!d.staff) return null;
  let f: { cars?: FindRow[] };
  try { f = await d.staff('offer_form', { pickup_at: instant(`${String(a.pickup_date)} 10:00`), return_at: instant(`${String(a.return_date)} 10:00`) }) as { cars?: FindRow[] }; } catch { return null; }
  const cars = f.cars ?? [];
  const free = cars.filter((c) => c.free === true);
  const span = `${String(a.pickup_date)} to ${String(a.return_date)}`;
  if (a.car) {
    const q = norm(String(a.car));
    const hit = cars.filter((c) => norm(String(c.name ?? '')).includes(q) || norm(String(c.plate ?? '')) === q || norm(String(c.car_code ?? '')).endsWith(q));
    if (!hit.length) return [{ type: 'text', text: `No car matches "${String(a.car)}". ${free.length} car${free.length === 1 ? ' is' : 's are'} free from ${span}.` }];
    return [{ type: 'text', text: hit.map((c) => `The ${String(c.name)}${c.plate ? ` (${String(c.plate)})` : ''} is ${c.free ? 'free' : 'not free'} from ${span}${c.free && c.daily_rate_cents ? ` (${money(c.daily_rate_cents)} a day)` : ''}`).join('; ') + '.' }];
  }
  return [{ type: 'results', title: `Free from ${span}`, empty: 'No car is free on those dates.',
    rows: free.slice(0, 15).map((c) => ({ title: `${String(c.name)}${c.plate ? ` (${String(c.plate)})` : ''}`, sub: [c.daily_rate_cents ? `${money(c.daily_rate_cents)} a day` : '', c.weekly_rate_cents ? `${money(c.weekly_rate_cents)} a week` : '', c.deposit_cents ? `deposit ${money(c.deposit_cents)}` : ''].filter(Boolean).join(' · '),
      href: d.who.portal === 'field' ? undefined : `${base(d.who.portal)}/vehicles/${String(c.id)}` })) }];
}

/** What a renter owes: each booking's open rental, fees and later charges, and the deposit (0129's booking money). */
async function bookingBalance(d: Deps, a: Record<string, unknown>): Promise<Out[]> {
  if (!d.staff) return [{ type: 'text', text: 'Open the booking\'s Money tab to see what is owed.' }];
  let numbers: string[];
  if (a.booking) numbers = [String(a.booking)];
  else {
    const rows = (await d.find('booking', String(a.customer))).filter((r) => ACTIVE.includes(String(r.status)));
    numbers = rows.slice(0, 4).map((r) => String(r.booking_number));
    if (!numbers.length) return [{ type: 'text', text: `No open booking matches "${String(a.customer)}".` }];
  }
  const out: Row[] = [];
  for (const n of numbers) {
    try {
      const m = await d.staff('booking_money', { booking: n }) as { booking_number: string; status: string; parts: Array<{ covers: string; open_cents: number }>; deposit_cents: number; deposit_pay_method?: string; deposit?: { status?: string; method?: string } | null };
      const part = (c: string) => Number(m.parts.find((x) => x.covers === c)?.open_cents ?? 0);
      const open = part('rental') + part('fees') + part('later');
      const dep = m.deposit ? `deposit ${String(m.deposit.status ?? 'taken').replace(/_/g, ' ')}` : m.deposit_cents ? `deposit ${money(m.deposit_cents)} not taken yet (${PAY_WORDS[String(m.deposit_pay_method ?? 'card')] ?? 'card'})` : 'no deposit';
      out.push({ title: `${m.booking_number}: ${open > 0 ? `${money(open)} owing` : 'nothing owing'}`, sub: [`${String(m.status).replace(/_/g, ' ')}`, `rental ${money(part('rental'))}`, `fees ${money(part('fees'))}`, `later ${money(part('later'))}`, dep].join(' · '),
        href: d.who.portal === 'field' ? undefined : `${base(d.who.portal)}/bookings/${m.booking_number}?tab=money` });
    } catch (e) { out.push({ title: n, sub: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not readable' }); }
  }
  return [{ type: 'results', title: a.booking ? `What is owed on ${String(a.booking)}` : `What "${String(a.customer)}" owes`, rows: out, empty: 'Nothing found.' }];
}

/** Looks up the names a change needs and builds the door call and the card. */
async function prepare(d: Deps, tool: ToolName, a: Record<string, unknown>): Promise<{ name: string; args: Record<string, unknown>; summary: string; details?: Details } | { out: Out }> {
  const k: Record<string, string | undefined> = {};
  switch (tool) {
    case 'record_payment': {
      if (a.invoice) {
        const p = await one(d, 'invoice', String(a.invoice), 'invoice', (r) => `${String(r.invoice_number)} (${String(r.owner)})`, (r) => norm(String(r.invoice_number)) === norm(String(a.invoice)));
        if ('out' in p) return p;
        a.invoice = String(p.row.invoice_number); k.owner = String(p.row.owner); k.balance = money(p.row.balance_cents);
      } else {
        const p = await one(d, 'booking', String(a.booking), 'booking', (r) => `${String(r.booking_number)} (${String(r.renter ?? '')})`, (r) => norm(String(r.booking_number)) === norm(String(a.booking)));
        if ('out' in p) return p;
        a.booking = String(p.row.booking_number); k.renter = String(p.row.renter ?? '');
        // a booking's payment is recorded by part (0129): the rental, the deposit, fees or a later charge
        return { name: 'record_booking_payment', summary: summary(tool, a, k), args: { booking: a.booking, covers: a.covers ?? 'rental', method: a.method, reference: a.reference ?? null,
          received_on: a.received_on, amount_cents: cents(a.amount as number | undefined) ?? null, note: a.note ?? null } };
      }
      return { name: 'manual_payment_record', summary: summary(tool, a, k), args: { invoice: a.invoice ?? null, booking: a.booking ?? null, method: a.method, reference: a.reference ?? null,
        received_on: a.received_on, amount_cents: cents(a.amount as number | undefined) ?? null, note: a.note ?? null } };
    }
    case 'publish_car': case 'set_rates': case 'add_rental': case 'mark_insured': {
      const p = await one(d, 'car', String(a.car), 'car', carLabel, carExact(String(a.car)));
      if ('out' in p) return p;
      k.car = String(p.row.name);
      if (tool === 'publish_car') return { name: 'listing_publish_now', summary: summary(tool, a, k), args: { vehicle_id: p.row.id } };
      // the insurer's written confirmation, as To do's Insurer confirmed (app.confirm_fleet_policy, 0078)
      if (tool === 'mark_insured') { k.today = d.today; return { name: 'insurer_confirm', summary: summary(tool, a, k), args: { vehicle_id: p.row.id, on: a.on ?? d.today, note: a.reference ?? null } }; }
      if (tool === 'set_rates') {
        const c = (v: unknown) => (v === undefined ? '' : String(cents(Number(v))));
        return { name: 'rate_card_save', summary: summary(tool, a, k), args: { vehicle: p.row.id, daily: c(a.daily), weekend: c(a.weekend), weekly: c(a.weekly), monthly: c(a.monthly), km_mode: 'default' } };
      }
      const from = instant(String(a.pickup_at)), to = instant(String(a.return_at));
      if (new Date(to) <= new Date(from)) return { out: { type: 'question', text: 'The return must be after the pickup. What are the pickup and return, each with a date and time?', options: [] } };
      const now = d.now ? d.now() : Date.now();
      k.phase = new Date(to).getTime() <= now ? 'past' : new Date(from).getTime() <= now ? 'in_progress' : 'upcoming';
      const c = await customerFor(d, a);
      if ('out' in c) return c;
      k.customer = c.name;
      const deposit = a.deposit_method ? { method: a.deposit_method } : undefined;
      const args = {
        vehicle_id: p.row.id, pickup_at: from, return_at: to, booking_type: 'standard', coverage_option: 1, pickup_method: 'collected', return_method: 'returned', source: 'phone',
        sales_choice: a.sourced_by_me ? 'sourced' : 'for_carmacars', note: a.note ?? undefined, ...(c.renterId ? { renter_id: c.renterId } : { renter: { full_name: a.renter_name, email: a.renter_email, mobile: a.renter_mobile, date_of_birth: a.renter_date_of_birth,
          licence_number: a.licence_number, licence_class: 'G', licence_issuer: 'ON' } }),
        drivers: [{ role: 'renter', date_of_birth: a.renter_date_of_birth ?? c.dob }], additional_drivers: [],
        payment: { mode: a.payment, method: a.method, reference: a.reference, received_on: d.today, amount_cents: cents(a.amount as number | undefined) },
        ...(deposit ? { deposit } : {}), ...(a.agreement ? { agreement: a.agreement } : {}) };
      // the price as the offer screen works it out (rolled back), for the card
      const priced = await preview(d, { ...(c.renterId ? { renter_id: c.renterId } : { renter: { full_name: a.renter_name, email: a.renter_email, mobile: a.renter_mobile, date_of_birth: a.renter_date_of_birth } }),
        vehicle_id: p.row.id, pickup_at: from, return_at: to, source: 'phone', coverage_option: 1, deposit_pay_method: a.deposit_method ?? 'card' });
      const details: Details = [
        { title: 'Rental', rows: [{ label: 'Customer', value: c.label }, { label: 'Car', value: k.car! }, { label: 'Pickup', value: shortDate(String(a.pickup_at)) }, { label: 'Return', value: shortDate(String(a.return_at)) },
          ...(k.phase === 'in_progress' ? [{ label: 'Status', value: 'Already underway: recorded on trip' }] : k.phase === 'past' ? [{ label: 'Status', value: 'Already returned: recorded as past' }] : [])] },
        priceSection(priced),
        { title: 'Payments', rows: [
          { label: 'Rental', value: a.payment === 'other_way' ? `Paid by ${PAY_WORDS[String(a.method)] ?? 'another way'}${a.amount ? ` (${dollars(Number(a.amount))})` : ''}${a.reference ? `, reference ${String(a.reference)}` : ''}` : 'Payment link emailed to the renter' },
          { label: 'Deposit', value: `By ${PAY_WORDS[String(a.deposit_method ?? 'card')]}${priced.ok && priced.booking.deposit_cents ? ` (${money(priced.booking.deposit_cents)})` : ''}` },
          { label: 'Agreement', value: a.agreement === 'paper' ? 'Signed on paper (a task asks for the scan)' : 'Signing link emailed to the renter' }] }];
      return { name: 'manual_rental_create', summary: summary(tool, a, k), args, details };
    }
    case 'create_offer': {
      const p = await one(d, 'car', String(a.car), 'car', carLabel, carExact(String(a.car)));
      if ('out' in p) return p;
      k.car = String(p.row.name);
      const from = instant(String(a.pickup_at)), to = instant(String(a.return_at));
      if (new Date(to) <= new Date(from)) return { out: { type: 'question', text: 'The return must be after the pickup. What are the pickup and return, each with a date and time?', options: [] } };
      const c = await customerFor(d, a);
      if ('out' in c) return c;
      k.customer = c.name;
      if (!c.renterId && !a.renter_date_of_birth) return { out: { type: 'question', text: `What is ${String(a.renter_name)}'s date of birth (YYYY-MM-DD)? The driver's age decides the car and the young driver fee.`, options: [] } };
      const notify = String(a.notify ?? 'email');
      const args: Record<string, unknown> = {
        ...(c.renterId ? { renter_id: c.renterId } : { renter: { full_name: a.renter_name, email: a.renter_email, mobile: a.renter_mobile, date_of_birth: a.renter_date_of_birth } }),
        vehicle_id: p.row.id, pickup_at: from, return_at: to, source: 'phone', sales_choice: a.sourced_by_me ? 'sourced' : 'for_carmacars',
        rental_pay_method: a.rental_pay ?? 'card', deposit_pay_method: a.deposit_pay ?? 'card',
        message: a.message ?? null, notify: notify !== 'none', channels: { email: notify === 'email' || notify === 'both', text: notify === 'text' || notify === 'both' } };
      if (a.coverage) args.coverage_option = Number(a.coverage);
      if (a.rental_total !== undefined) { args.rental_charge_cents = cents(Number(a.rental_total)); args.price_tax = 'plus'; args.price_reason = a.price_reason; }
      if (a.expires_hours) args.expires_at = new Date((d.now ? d.now() : Date.now()) + Number(a.expires_hours) * 3_600_000).toISOString();
      const priced = await preview(d, args);
      if (!priced.ok) return { out: { type: 'text', text: `The offer cannot be made: ${priced.error}. Nothing was sent.` } };
      if (priced.available === false) return { out: { type: 'question', text: `The ${k.car} is not free from ${shortDate(String(a.pickup_at))} to ${shortDate(String(a.return_at))}. Which other car or dates?`, options: [] } };
      const b = priced.booking;
      k.due = money(b.renter_due_at_booking_cents ?? b.total_due_at_booking_cents);
      const details: Details = [
        { title: 'Offer', rows: [{ label: 'Customer', value: c.label }, { label: 'Car', value: k.car }, { label: 'Pickup', value: shortDate(String(a.pickup_at)) }, { label: 'Return', value: shortDate(String(a.return_at)) },
          { label: 'Days', value: String(b.billable_days ?? '') }, { label: 'Client', value: a.sourced_by_me ? 'Found by you' : 'Entered for CarmaCars' }] },
        priceSection(priced),
        { title: 'Payments', rows: [
          { label: 'Rental', value: a.rental_pay && a.rental_pay !== 'card' ? `By ${PAY_WORDS[String(a.rental_pay)]}: staff confirm the booking once the money is in` : 'By card, when the customer signs and pays online' },
          { label: 'Deposit', value: `${money(b.deposit_cents)} by ${PAY_WORDS[String(a.deposit_pay ?? 'card')]} at pickup` },
          { label: 'Sent', value: notify === 'none' ? 'Not sent: send the link from the booking' : `By ${notify === 'both' ? 'email and text' : notify}${a.expires_hours ? `, open ${String(a.expires_hours)} hours` : ''}` }] }];
      return { name: 'offer_create', summary: summary(tool, a, k), args, details };
    }
    case 'send_payment_link': {
      if (a.booking) {
        const p = await one(d, 'booking', String(a.booking), 'booking', (r) => `${String(r.booking_number)} (${String(r.renter ?? '')})`, (r) => norm(String(r.booking_number)) === norm(String(a.booking)));
        if ('out' in p) return p;
        if (!['offered', 'pending_payment'].includes(String(p.row.status))) return { out: { type: 'text', text: `Booking ${String(p.row.booking_number)} is ${String(p.row.status).replace(/_/g, ' ')}: there is no offer to pay. Open the booking to send an offer first.` } };
        a.booking = String(p.row.booking_number); k.renter = String(p.row.renter ?? '');
        return { name: 'resend_offer', summary: summary(tool, a, k), args: { booking: a.booking } };
      }
      const p = await one(d, 'invoice', String(a.invoice), 'invoice', (r) => `${String(r.invoice_number)} (${String(r.owner)})`, (r) => norm(String(r.invoice_number)) === norm(String(a.invoice)));
      if ('out' in p) return p;
      a.invoice = String(p.row.invoice_number); k.owner = String(p.row.owner);
      return { name: 'owner_invoice_resend', summary: summary(tool, a, k), args: { id: p.row.id } };
    }
    case 'confirm_toll': {
      const p = await one(d, 'toll', String(a.toll), 'toll notice', (r) => `${String(r.notice_number)} (${String(r.plate ?? '')})`, (r) => norm(String(r.notice_number ?? '')) === norm(String(a.toll)));
      if ('out' in p) return p;
      if (!p.row.booking_number && p.row.matched_to === 'unmatched') return { out: { type: 'text', text: `Notice ${String(p.row.notice_number)} has no suggested match. Open Tolls to match it by hand.` } };
      k.match = p.row.booking_number ? `booking ${String(p.row.booking_number)}` : String(p.row.matched_to).replace(/_/g, ' ');
      return { name: 'toll_confirm', summary: summary(tool, { ...a, toll: p.row.notice_number }, k), args: { id: p.row.id } };
    }
    case 'create_task': {
      const queue = a.queue ?? (d.who.portal === 'va' ? d.who.fn : 'admin');
      if (a.booking) {
        const p = await one(d, 'booking', String(a.booking), 'booking', (r) => String(r.booking_number), (r) => norm(String(r.booking_number)) === norm(String(a.booking)));
        if ('out' in p) return p;
        a.booking = String(p.row.booking_number);
      }
      return { name: 'task_create', summary: summary(tool, { ...a, queue }, k), args: { title: a.title, detail: a.detail ?? null, queue, priority: a.priority ?? 'normal',
        due_at: a.due ? instant(String(a.due)) : null, booking: a.booking ?? null } };
    }
    default: return { out: { type: 'text', text: 'That is done from the screens.' } };
  }
}

/** One message from the staff member: the answer as cards, and what the model used. */
export async function ask(d: Deps, input: { text: string; history?: Turn[] }): Promise<{ out: Out[]; steps: number }> {
  const text = input.text.trim().slice(0, 1000);
  if (!text) return { out: [{ type: 'question', text: 'What can I help with?', options: [] }], steps: 0 };
  const gate = await d.gate();
  const paused = pauseMessage('assistant', { ...gate, service: d.model.service });
  if (paused) return { out: [{ type: 'paused', text: paused }], steps: 0 };
  const tools = toolsFor(d.who);
  const system = systemPrompt(d.who, d.today, tools);
  const turns: Turn[] = [...(input.history ?? []).slice(-HISTORY_TURNS).map((t) => ({ role: t.role, text: t.text.slice(0, 600) })), { role: 'user', text }];
  const now = d.now ?? (() => Date.now());
  const t0 = now();
  const r = await d.model.step(system, turns, tools);
  await d.record({ units: r.usage?.units ?? 0, unit: r.usage?.unit ?? (d.model.service === 'claude' ? 'microusd' : 'neurons'), ok: r.ok, model: r.model, error: r.ok ? undefined : `${r.reason}: ${r.message}`, ms: now() - t0 }).catch(() => undefined);
  if (!r.ok) {
    if (r.reason === 'quota') return { out: [{ type: 'paused', text: pauseMessage('assistant', { ok: false, service: d.model.service })! }], steps: 1 };
    return { out: [{ type: 'text', text: 'The assistant could not answer just now. Try again in a minute; everything still works from the screens and pop-ups.' }], steps: 1 };
  }
  const s = r.step;
  if (s.action === 'ask') return { out: [{ type: 'question', text: (s.question || s.reply || 'Can you tell me more?').slice(0, 500), options: (s.options ?? []).slice(0, 6).map((o) => String(o).slice(0, 120)) }], steps: 1 };
  if (s.action !== 'tool' || !s.tool) return { out: [{ type: 'text', text: (s.reply || 'I am not sure. Can you say it another way?').slice(0, 800) }], steps: 1 };
  const tool = s.tool as ToolName;
  if (!(tool in TOOLS) || !tools.includes(tool)) return { out: [{ type: 'text', text: 'I cannot do that from here. Use the screens, or ask an Admin.' }], steps: 1 };
  const c = checkArgs(tool, tidyArgs(s.args));
  if (!c.ok) return { out: [{ type: 'question', text: `To ${TOOLS[tool].about.charAt(0).toLowerCase()}${TOOLS[tool].about.slice(1)}, I need: ${c.problem}.`, options: [] }], steps: 1 };
  try {
    if (!TOOLS[tool].change) return { out: await read(d, tool, c.args as Record<string, unknown>), steps: 1 };
    const p = await prepare(d, tool, { ...(c.args as Record<string, unknown>) });
    if ('out' in p) return { out: [p.out], steps: 1 };
    const prop = await d.propose({ tool, name: p.name, args: p.args, summary: p.summary, details: p.details });
    return { out: [{ type: 'proposal', id: prop.id, summary: prop.summary, ...(p.details?.length ? { details: p.details } : {}) }], steps: 1 };
  } catch (e) {
    const msg = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.';
    return { out: [{ type: 'text', text: `The database said: ${msg}` }], steps: 1 };
  }
}
