import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { fill, getBlocks, getTokens } from '@/lib/site';
import { textGenerator } from '@/integrations/llm';
import { ANSWER_SCHEMA, closest, isQuestion, readAnswer, systemPrompt, userPrompt, type Channel, type FaqEntry } from '@/features/auto-reply/faq';

// AI auto-replies (release 36, migration 2110): one incoming question on one channel. The database says whether the site may
// answer (the channel on, the sender's answers of the day, a person not already talking with them, room in the free Workers
// AI allowance); any failure there means no answer (fail closed: never past the free tier). The FAQ entries closest to the
// question go to the small Workers AI model (through the usage guard, purpose faq_reply); the database records what was
// done and decides the rest (a text held for the quiet hours, a To do for staff when the model is not sure). The caller
// sends what comes back on its channel (sendSms, the email reply, the Meta message).
const SR = { role: 'service_role' as const };
interface Gate { allowed: boolean; reason?: string; model?: string; min_confidence?: number; handoff_text?: string | null; brand?: string }
export interface Outcome { status: 'sent' | 'queued' | 'handoff' | 'skipped' | 'failed'; answer: string | null; reason: string | null; send: Array<{ id: string; to: string; body: string }>; handoff_text?: string | null }

let faqCache: { at: number; rows: FaqEntry[] } | null = null;
const strip = (s: string) => s.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
/** The site's FAQ (the FAQ page's groups and the owners' FAQ), the {{tokens}} filled, read every 10 minutes at most. */
export async function faqEntries(): Promise<FaqEntry[]> {
  if (faqCache && Date.now() - faqCache.at < 10 * 60_000) return faqCache.rows;
  const [blocks, t] = await Promise.all([getBlocks(), getTokens()]);
  const F = (s: string) => { try { return fill(s, t); } catch { return s.replace(/\{\{\w+\}\}/g, ''); } };
  const rows: FaqEntry[] = [];
  for (const b of blocks.filter((x) => x.kind === 'faq')) {
    const items = (b.data.items as Array<{ question?: string; answer?: string }> | undefined) ?? [];
    items.forEach((q, i) => { if (q.question && q.answer) rows.push({ key: `${b.key}#${i + 1}`, q: strip(F(q.question)), a: strip(F(q.answer)) }); });
  }
  faqCache = { at: Date.now(), rows };
  return rows;
}

async function record(p: Record<string, unknown>): Promise<Outcome> {
  const r = (await rpc('server_auto_reply_record', { p: p as Json }, SR)) as unknown as { status: Outcome['status']; reason: string | null; send?: Outcome['send']; handoff_text?: string | null };
  return { status: r.status, answer: r.status === 'sent' || r.status === 'queued' ? String(p.answer ?? '') || null : null, reason: r.reason, send: r.send ?? [], handoff_text: r.handoff_text ?? null };
}

/** Answers one question when the site may, or hands it to staff. Never throws: a failure is recorded and nothing is sent. */
export async function autoReply(channel: Channel, sender: string, question: string): Promise<Outcome> {
  const text = question.replace(/\s+/g, ' ').trim().slice(0, 1000);
  const base = { channel, sender, question: text };
  try {
    if (!isQuestion(text)) return { status: 'skipped', answer: null, reason: 'not a question', send: [] };
    let gate: Gate;
    try { gate = (await rpc('server_auto_reply_gate', { p: { channel, sender } }, SR)) as unknown as Gate; }
    catch { return { status: 'skipped', answer: null, reason: 'the gate could not be read', send: [] }; }
    if (!gate?.allowed) {
      // off or no room: recorded only when it matters to staff (the allowance or the daily cap), never the sender told
      if (gate?.reason && !/off in Program settings|unknown channel/.test(gate.reason)) await record({ ...base, status: 'skipped', reason: gate.reason }).catch(() => undefined);
      return { status: 'skipped', answer: null, reason: gate?.reason ?? 'not allowed', send: [] };
    }
    const entries = closest(text, await faqEntries());
    // nothing in the FAQ is close: no model call at all, straight to staff
    if (!entries.length) return await record({ ...base, answer: '', confident: false, reason: 'no FAQ entry is close to it' });
    const gen = await textGenerator(gate.model, 12_000);
    if (gen.name !== 'workers-ai') return await record({ ...base, status: 'skipped', reason: 'Workers AI is not connected here' });
    const t0 = Date.now();
    const r = await gen.generate<unknown>({ task: 'faq_reply', system: systemPrompt(gate.brand ?? 'CarmaCars'), prompt: userPrompt(text, entries, channel), schema: ANSWER_SCHEMA,
      maxOutputTokens: channel === 'sms' ? 140 : 320, temperature: 0.1 });
    const call = { model: gen.model, neurons: r.usage?.neurons ?? 0, duration_ms: Date.now() - t0, ok: r.ok, error: r.ok ? null : `${r.reason}: ${r.message}`.slice(0, 300) };
    if (!r.ok) return await record({ ...base, ...call, answer: '', confident: false, reason: r.reason === 'quota' ? 'the free Workers AI allowance of the day is used' : 'the model did not answer' });
    const a = readAnswer(r.data, entries, channel);
    return await record({ ...base, ...call, answer: a.answer, confident: a.confident, confidence: a.confidence, faq: a.faq });
  } catch (e) {
    console.error('auto-reply', e instanceof Error ? e.message.slice(0, 200) : e);
    return { status: 'failed', answer: null, reason: 'error', send: [] };
  }
}

/** The live chat's assistant answers only while AI auto-replies are on for the chat (and the chat's own switch, 0060). */
export async function chatAutoReplyOn(): Promise<boolean> {
  try { return (await rpc('server_auto_reply_chat_on', {}, SR)) === true; } catch { return true; }
}
