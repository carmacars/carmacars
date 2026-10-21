// The staff assistant (migration 0080): one question in, a short answer out. The model picks one step (a reply, a
// question, or a tool with its arguments, as JSON); a read runs at once and its result is the answer (no second model
// call, to save neurons); a change is checked, its names are looked up in the database, and it comes back as a card
// that runs only after Confirm. Pure: every outside service is passed in (src/server/assistant.ts wires the real
// ones), so the unit tests run it with a stub model.
import { checkArgs, cents, summary, TOOLS, toolsFor, type Portal, type ToolName, type Who } from './tools.ts';
import { pauseMessage } from '../usage/model.ts';
import { torontoInstant } from '../../lib/dates.ts';

export interface Turn { role: 'user' | 'assistant'; text: string }
export interface Step { action: 'reply' | 'tool' | 'ask'; reply?: string; tool?: string; args?: Record<string, unknown>; question?: string; options?: string[] }
export interface Row { title: string; sub?: string; href?: string }
export type Out =
  | { type: 'text'; text: string }
  | { type: 'results'; title: string; rows: Row[]; empty?: string }
  | { type: 'proposal'; id: string; summary: string }
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
  propose(p: { tool: ToolName; name: string; args: Record<string, unknown>; summary: string }): Promise<{ id: string; summary: string }>;
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
    'Amounts are in dollars. Dates YYYY-MM-DD; times HH:MM, 24 hours, Toronto. Marking a car insured is done on the car\'s page, not here.',
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
const carExact = (q: string) => (r: FindRow) => norm(String(r.plate ?? '')) === norm(q) || norm(String(r.fleet_number ?? '')) === norm(q) || norm(String(r.name ?? '')) === norm(q);

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
        car: (r) => ({ title: `${String(r.name)}${r.sample ? ' (example car)' : ''}`, sub: [r.plate && `plate ${String(r.plate)}`, String(r.status).replace(/_/g, ' '), r.listing && `listing ${String(r.listing)}`].filter(Boolean).join(' · '), href: d.who.portal === 'field' ? undefined : `${b}/vehicles/${String(r.id)}` }),
        invoice: (r) => ({ title: `${String(r.invoice_number)} · ${String(r.owner)}`, sub: `${String(r.status).replace(/_/g, ' ')} · total ${money(r.total_cents)} · balance ${money(r.balance_cents)}${r.due_on ? ` · due ${String(r.due_on)}` : ''}`, href: d.who.portal === 'admin' ? `/admin/invoices/${String(r.invoice_number)}` : undefined }),
        toll: (r) => ({ title: `${String(r.notice_number ?? 'Notice')} · ${String(r.authority ?? r.kind)}`, sub: `plate ${String(r.plate ?? '')} · ${when(r.occurred_at)} · ${money(r.amount_cents)}${r.booking_number ? ` · suggested: ${String(r.booking_number)}` : ' · no suggested match'}` })
      };
      return [{ type: 'results', title: `${String(a.kind).replace(/^./, (c) => c.toUpperCase())} matching "${String(a.q)}"`, rows: rows.map(map[String(a.kind)]!), empty: 'Nothing matches. Try a number, a plate or another spelling.' }];
    }
    case 'availability': {
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
    case 'draft_message': {
      const href = d.who.portal === 'admin' ? (a.booking ? `/admin/bookings/${String(a.booking)}` : '/admin/messages') : d.who.portal === 'va' ? (a.booking ? `/va/bookings/${String(a.booking)}` : '/va/messages') : '/field';
      return [{ type: 'draft', to: a.to as 'renter', name: String(a.name), text: String(a.text), href }];
    }
    default: return [];
  }
}

/** Looks up the names a change needs and builds the door call and the card. */
async function prepare(d: Deps, tool: ToolName, a: Record<string, unknown>): Promise<{ name: string; args: Record<string, unknown>; summary: string } | { out: Out }> {
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
      }
      return { name: 'manual_payment_record', summary: summary(tool, a, k), args: { invoice: a.invoice ?? null, booking: a.booking ?? null, method: a.method, reference: a.reference ?? null,
        received_on: a.received_on, amount_cents: cents(a.amount as number | undefined) ?? null, note: a.note ?? null } };
    }
    case 'publish_car': case 'set_rates': case 'add_rental': {
      const p = await one(d, 'car', String(a.car), 'car', carLabel, carExact(String(a.car)));
      if ('out' in p) return p;
      k.car = String(p.row.name);
      if (tool === 'publish_car') return { name: 'listing_publish_now', summary: summary(tool, a, k), args: { vehicle_id: p.row.id } };
      if (tool === 'set_rates') {
        const c = (v: unknown) => (v === undefined ? '' : String(cents(Number(v))));
        return { name: 'rate_card_save', summary: summary(tool, a, k), args: { vehicle: p.row.id, daily: c(a.daily), weekend: c(a.weekend), weekly: c(a.weekly), monthly: c(a.monthly), km_mode: 'default' } };
      }
      const from = instant(String(a.pickup_at)), to = instant(String(a.return_at));
      if (new Date(to) <= new Date(from)) return { out: { type: 'question', text: 'The return must be after the pickup. What are the pickup and return, each with a date and time?', options: [] } };
      const now = d.now ? d.now() : Date.now();
      k.phase = new Date(to).getTime() <= now ? 'past' : new Date(from).getTime() <= now ? 'in_progress' : 'upcoming';
      // a renter already on file is used as they are
      const known = (await d.find('renter', String(a.renter_email)).catch(() => [])).filter((r) => String(r.email ?? '').toLowerCase() === String(a.renter_email).toLowerCase());
      const renter = known.length === 1 ? { renter_id: known[0]!.id } : { renter: { full_name: a.renter_name, email: a.renter_email, mobile: a.renter_mobile, date_of_birth: a.renter_date_of_birth,
        licence_number: a.licence_number, licence_class: 'G', licence_issuer: 'ON' } };
      return { name: 'manual_rental_create', summary: summary(tool, a, k), args: {
        vehicle_id: p.row.id, pickup_at: from, return_at: to, booking_type: 'standard', coverage_option: 1, pickup_method: 'collected', return_method: 'returned', source: 'phone',
        sales_choice: a.sourced_by_me ? 'sourced' : 'for_carmacars', note: a.note ?? undefined, ...renter,
        drivers: [{ role: 'renter', date_of_birth: a.renter_date_of_birth }], additional_drivers: [],
        payment: { mode: a.payment, method: a.method, reference: a.reference, received_on: d.today, amount_cents: cents(a.amount as number | undefined) } } };
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
    const prop = await d.propose({ tool, name: p.name, args: p.args, summary: p.summary });
    return { out: [{ type: 'proposal', id: prop.id, summary: prop.summary }], steps: 1 };
  } catch (e) {
    const msg = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.';
    return { out: [{ type: 'text', text: `The database said: ${msg}` }], steps: 1 };
  }
}
