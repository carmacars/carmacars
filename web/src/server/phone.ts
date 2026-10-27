import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { door } from '@/server/door';
import { contactsBook, phoneLine, webhookSecrets } from '@/integrations/phone';
import { syncContacts, type Due, type SyncDb } from '@/features/phone/quo-contacts';
import { textGenerator } from '@/integrations/llm';
import { parseQuoEvent, transcriptText, verifyQuoSignature, type PhoneEvent } from '@/features/phone/webhook';

// The business phone line (migration 0085): what the Worker does with Quo. The database decides (matching, the
// missed-call rule, opt-outs, templates, who may do what); this file verifies deliveries, sends texts through Quo from
// the CarmaCars number and calls Workers AI for drafts and summaries within the database's allowance.
const SR = { role: 'service_role' as const };
type Send = { id: string; to: string; body: string };

let ours: { at: number; n: string | null } | null = null;
async function ourNumber(): Promise<string | null> {
  if (!ours || Date.now() - ours.at > 5 * 60_000) {
    const s = (await rpc('site_settings_public', {} as never, { role: 'anon' })) as unknown as { phone?: string | null } | null;
    ours = { at: Date.now(), n: s?.phone ?? null };
  }
  return ours.n;
}

/** Sends texts the database released (status sending) and reports each result back. */
export async function sendTexts(rows: Send[], from?: string | null): Promise<Array<{ id: string; ok: boolean; error?: string }>> {
  const line = phoneLine();
  const sender = from ?? (await ourNumber());
  const out: Array<{ id: string; ok: boolean; error?: string }> = [];
  for (const r of rows) {
    const res = sender ? await line.sendText({ from: sender, to: r.to, body: r.body }) : { ok: false, id: null, error: 'The CarmaCars number is not set (Site settings, Phone)', permanent: false };
    await rpc('server_phone_sent', { p: { id: r.id, ok: res.ok, quo_id: res.id, error: res.error ?? null, permanent: !!res.permanent } as unknown as Json }, SR);
    out.push({ id: r.id, ok: res.ok, error: res.error });
  }
  return out;
}

export interface WebhookResult { status: number; body: Record<string, unknown> }

/** One delivery from Quo: verified on the raw body, read, recorded; a missed-call text is sent at once. */
export async function handleQuoWebhook(raw: string, header: (n: string) => string | null): Promise<WebhookResult> {
  const v = await verifyQuoSignature(raw, header, webhookSecrets());
  if (!v.ok) return { status: 401, body: { error: 'invalid signature' } };
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return { status: 400, body: { error: 'not JSON' } }; }
  const ev: PhoneEvent | null = parseQuoEvent(body, v.id ?? header('webhook-id'), await ourNumber());
  if (!ev) return { status: 200, body: { ignored: 'not an event' } };
  const r = (await rpc('server_phone_event', { p: ev as unknown as Json }, SR)) as unknown as { ok: boolean; send?: Send[]; duplicate?: boolean; ignored?: string };
  if (r.send?.length) await sendTexts(r.send);
  return { status: 200, body: { received: true, duplicate: !!r.duplicate, ignored: r.ignored ?? null } };
}

interface Budget { ok: boolean; drafts: boolean; summaries: boolean; model?: string }
const SUMMARY_SCHEMA = { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'] };
const DRAFT_SCHEMA = { type: 'object', properties: { reply: { type: 'string' } }, required: ['reply'] };
const clean = (s: string, max: number) => s.replace(/\s+/g, ' ').replace(/\u2014/g, ',').replace(/\u2013/g, '-').trim().slice(0, max);

/** The usage guard (0080): Workers AI is paused for the day once its included allowance is used (or all AI use of the day
 *  reached the cap). The phone line's own budget (phone_ai_daily_neurons) still applies on top. A guard that cannot be
 *  read does not stop the phone line. */
async function workersAiPaused(): Promise<boolean> {
  try {
    const g = (await rpc('server_usage_gate', { p_service: 'workers_ai' }, SR)) as unknown as { paused?: boolean; used?: number | string; all_cap?: number | string };
    return g.paused === true || (g.all_cap !== undefined && g.used !== undefined && Number(g.used) >= Number(g.all_cap));
  } catch { return false; }
}

/** The five-minute job: booking texts that are due, the AI one-liners of calls Quo did not summarise, and (0179) the
 *  Quo contacts of people who changed. A failure of one part never stops the other. */
export async function runPhoneJob(): Promise<Record<string, unknown>> {
  let texts: Record<string, unknown> = {};
  let failed: unknown = null;
  try { texts = await runTextsJob(); } catch (e) { failed = e; }
  let contacts: Record<string, unknown>;
  try { contacts = { ...(await syncContacts(contactsDb, contactsBook())) }; } catch (e) { contacts = { ok: false, error: e instanceof Error ? e.message.slice(0, 200) : 'failed' }; }
  if (failed) throw failed;
  return { ...texts, contacts };
}

/** Quo contacts (0179): the database's side of the sync (src/features/phone/quo-contacts.ts). */
const contactsDb: SyncDb = {
  due: async (limit) => (await rpc('server_quo_contacts_due', { p_limit: limit }, SR)) as unknown as Due,
  found: (p) => rpc('server_quo_contacts_found', { p: p as unknown as Json }, SR),
  done: (p) => rpc('server_quo_contact_done', { p: p as unknown as Json }, SR),
  run: (p) => rpc('server_quo_contacts_run', { p: p as unknown as Json }, SR)
};

async function runTextsJob(): Promise<Record<string, unknown>> {
  if (!phoneLine().ready) return { ok: true, skipped: 'QUO_API_KEY is not set' };
  const due = (await rpc('server_phone_due', { p_limit: 20 }, SR)) as unknown as { texts: Send[]; summaries: Array<{ id: string; transcript: PhoneEvent['transcript'] | null }>; ai: Budget; from: string | null };
  const sent = await sendTexts(due.texts, due.from);
  let summaries = 0;
  if (due.summaries.length && due.ai.ok && due.ai.summaries && await workersAiPaused()) due.ai.ok = false;
  for (const s of due.summaries) {
    const text = transcriptText(s.transcript);
    if (!text || !due.ai.ok || !due.ai.summaries) { await rpc('server_phone_summary', { p: { id: s.id, summary: '', ok: false, neurons: 0, error: !text ? 'no transcript' : 'AI allowance used or off' } as unknown as Json }, SR); continue; }
    const t0 = Date.now();
    const gen = await textGenerator(due.ai.model, 20_000);
    const r = await gen.generate<{ summary: string }>({ task: 'phone_summary', maxOutputTokens: 80, temperature: 0.2, schema: SUMMARY_SCHEMA,
      system: 'You summarise phone calls of CarmaCars, a car rental company in Toronto, for its staff. Answer in JSON {"summary": "..."}: one plain sentence of at most 20 words saying what the caller wanted and what was agreed. No names of insurers, no long dashes, nothing that is not in the transcript.',
      prompt: `<transcript>\n${text}\n</transcript>` });
    await rpc('server_phone_summary', { p: { id: s.id, summary: r.ok ? clean(r.data.summary ?? '', 200) : '', ok: r.ok, neurons: r.usage?.neurons ?? 0, error: r.ok ? null : r.message, duration_ms: Date.now() - t0 } as unknown as Json }, SR);
    summaries++;
    due.ai.ok = false; // one model call per run keeps the job light; the rest wait five minutes
  }
  return { ok: true, sent: sent.filter((x) => x.ok).length, failed: sent.filter((x) => !x.ok).length, summaries };
}

type Door = (call: 'admin_do' | 'va_do', name: string, p: Record<string, unknown>) => Promise<Record<string, unknown>>;
export function staffDoor(userId: string, admin: boolean, aal: 'aal1' | 'aal2' | null): Door {
  return (call, name, p) => door(userId, admin ? 'admin_do' : call, name, p, aal);
}

/** A staff reply: the database checks and queues it (refusing an opted-out number), this sends it at once. */
export async function staffReply(d: Door, id: string, body: string): Promise<{ ok: boolean; error?: string }> {
  const r = (await d('va_do', 'phone_reply', { id, body })) as { send?: Send; from?: string };
  if (!r.send) return { ok: false, error: 'Nothing to send' };
  const [res] = await sendTexts([r.send], r.from);
  return res!.ok ? { ok: true } : { ok: false, error: `Not sent: ${res!.error ?? 'Quo refused it'}` };
}

/** A suggested reply (never sent): from the conversation, the booking and the site's facts. */
export async function staffDraft(d: Door, id: string): Promise<{ ok: boolean; draft?: string; error?: string }> {
  const c = (await d('va_do', 'phone_draft', { id })) as { ai: Budget; who: string; booking: Record<string, unknown> | null; site: Record<string, unknown>; messages: Array<Record<string, unknown>> };
  if (!c.ai.ok || await workersAiPaused()) return { ok: false, error: 'The AI allowance for today is used. Write the reply yourself.' };
  const t0 = Date.now();
  const gen = await textGenerator(c.ai.model, 20_000);
  const r = await gen.generate<{ reply: string }>({ task: 'phone_draft', maxOutputTokens: 160, temperature: 0.3, schema: DRAFT_SCHEMA,
    system: 'You draft text message replies for CarmaCars staff (car rental, Toronto). Answer in JSON {"reply": "..."}: one short, friendly text under 300 characters, signed "CarmaCars". Use only the facts given. Never quote a price, promise a car, a discount or a refund, or mention insurance or coverage; if they ask for any of that, say a team member will confirm. No long dashes. A person reviews and sends it.',
    prompt: `<who>${c.who}</who>\n<site>${JSON.stringify(c.site)}</site>\n<booking>${JSON.stringify(c.booking)}</booking>\n<conversation>\n${c.messages.map((m) => `${m.from === 'customer' ? 'Customer' : 'CarmaCars'} (${String(m.at)}): ${String(m.text ?? '')}`).join('\n')}\n</conversation>` });
  await rpc('server_phone_ai_log', { p: { purpose: 'phone_draft', ok: r.ok, neurons: r.usage?.neurons ?? 0, error: r.ok ? null : r.message, duration_ms: Date.now() - t0 } as unknown as Json }, SR);
  if (!r.ok || !r.data.reply) return { ok: false, error: 'No suggestion this time. Write the reply yourself.' };
  let draft = clean(r.data.reply, 480);
  if (/insurance|coverage|\$\s?\d/i.test(draft)) return { ok: false, error: 'The suggestion mentioned prices or coverage, so it was dropped. Write the reply yourself.' };
  if (!/CarmaCars/.test(draft)) draft = `${draft} CarmaCars`;
  return { ok: true, draft };
}
