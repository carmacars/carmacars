import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { torontoInstant } from '@/lib/dates';
import { textGenerator } from '@/integrations/llm';
import { PAUSE } from '@/features/usage/model';
import { runAgent, STEP_SCHEMA, type AgentResult, type ChatFacts, type QuoteResult, type SearchRow, type Step, type Turn } from '@/features/chat/agent';

// Live chat (migration 0060): the assistant's dependencies on the real database and model. The facts are read once
// every few minutes per Worker instance; prices always come fresh from the pricing functions.
const SR = { role: 'service_role' as const };
let cache: { at: number; facts: ChatFacts & { budget?: Record<string, unknown> } } | null = null;

export async function chatFacts(): Promise<ChatFacts> {
  if (!cache || Date.now() - cache.at > 5 * 60_000) cache = { at: Date.now(), facts: (await rpc('server_chat_facts', {}, SR)) as unknown as ChatFacts };
  return cache.facts;
}

export interface VisitorMessageState { ok: boolean; error?: string; id?: number; status?: string; ai?: boolean; ai_reason?: string | null; model?: string; name?: string | null; email?: string | null; phone?: string | null; page?: string | null; car?: string | null; history?: Turn[] }

/** The assistant answers one visitor message: a reply stored for the visitor, or a hand-over to a person. */
export async function answer(token: string, st: VisitorMessageState, text: string): Promise<AgentResult> {
  const facts = await chatFacts();
  const t0 = Date.now();
  const gen = await textGenerator(st.model, 25_000);
  const result = await runAgent({
    facts,
    model: async (system, prompt) => {
      const r = await gen.generate<Step>({ task: 'chat', system, prompt, schema: STEP_SCHEMA as unknown as Record<string, unknown>, maxOutputTokens: 400, temperature: 0.2 });
      return r.ok ? { ok: true, data: r.data, usage: r.usage, model: r.model } : { ok: false, reason: r.reason, message: r.message, usage: r.usage };
    },
    quote: async (vehicle, from, to) => (await rpc('quote_booking', { p_vehicle: vehicle, p_pickup: from, p_return: to, p_options: {} }, { role: 'anon' })) as unknown as QuoteResult,
    search: async (from, to, filters) => (await rpc('search_available', { p_pickup: from, p_return: to, p_filters: filters as Json }, { role: 'anon' })) as unknown as SearchRow[],
    lead: async (a) => (await rpc('server_chat_lead', { p_token: token, p: a as unknown as Json }, SR)) as unknown as { ok: boolean; missing?: string; reference?: string },
    instant: torontoInstant
  }, { history: st.history ?? [], text, page: st.page, car: st.car, name: st.name, email: st.email, phone: st.phone });
  const usage = { neurons: result.neurons, model: result.model ?? st.model, ok: result.ok, error: result.error, duration_ms: Date.now() - t0 };
  if (result.reply) {
    await rpc('server_chat_ai_reply', { p_token: token, p: { body: result.reply, car: result.meta.car, meta: result.meta, ...usage } as unknown as Json }, SR);
  } else {
    await rpc('server_chat_ai_reply', { p_token: token, p: { body: null, ...usage } as unknown as Json }, SR);
    // Workers AI refused for its daily allowance (quota): the visitor reads that the assistant rests (the usage guard, 0080)
    if (result.error?.startsWith('quota')) await rpc('server_chat_handoff', { p_token: token, p_reason: 'the assistant is off for today (daily included AI usage reached)', p_message: PAUSE.chat }, SR);
    else await rpc('server_chat_handoff', { p_token: token, p_reason: result.handoff?.reason ?? 'the assistant handed over' }, SR);
  }
  return result;
}
