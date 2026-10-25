// The staff assistant's model, behind one interface (migration 0080): Workers AI Llama 3.3 70B by default (the Worker's
// AI binding, as the live chat uses it), Claude when the Worker has ANTHROPIC_API_KEY (the model in Program settings),
// and a deterministic stub for local work and the tests. Each returns one step as JSON and what it used (neurons, or
// micro-dollars for Claude), so the usage guard counts both.
import { DRAFT_MODEL, neuronsFor, type AiBinding } from '../../integrations/llm/workers-ai.ts';
import { jsonSchemas, type ToolName } from './tools.ts';
import { STEP_SCHEMA, type AssistantModel, type ModelResult, type Step, type Turn } from './agent.ts';

const asText = (turns: Turn[]) => turns.map((t) => ({ role: t.role, content: t.text }));
const steps = (data: unknown): Step | null => {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
  const s = data as Step;
  return ['reply', 'tool', 'ask'].includes(s.action) ? s : null;
};

export function workersAiModel(ai: AiBinding, model = DRAFT_MODEL, timeoutMs = 20_000): AssistantModel {
  return {
    name: 'workers-ai', service: 'workers_ai',
    async step(system, turns): Promise<ModelResult> {
      let raw: unknown;
      try {
        raw = await Promise.race([
          ai.run(model, { messages: [{ role: 'system', content: system }, ...asText(turns)], response_format: { type: 'json_schema', json_schema: STEP_SCHEMA }, max_tokens: 400, temperature: 0.1 }),
          new Promise((_, no) => setTimeout(() => no(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), timeoutMs))
        ]);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof Error && e.name === 'TimeoutError') return { ok: false, reason: 'timeout', message: 'The model did not answer in time', model };
        if (/4006|neuron|allocation|429|3036|rate limit/i.test(msg)) return { ok: false, reason: 'quota', message: msg.slice(0, 200), model };
        return { ok: false, reason: 'unavailable', message: msg.slice(0, 200), model };
      }
      const r = (raw ?? {}) as { response?: unknown; usage?: { prompt_tokens?: number; completion_tokens?: number } };
      const out = typeof r.response === 'string' ? r.response : JSON.stringify(r.response ?? '');
      const input = r.usage?.prompt_tokens || Math.ceil((system.length + turns.reduce((n, t) => n + t.text.length, 0)) / 4);
      const output = r.usage?.completion_tokens || Math.ceil(out.length / 4);
      const usage = { units: neuronsFor(model, input, output), unit: 'neurons' as const };
      let data: unknown = r.response;
      if (typeof data === 'string') { try { data = JSON.parse(data.trim().replace(/^```(?:json)?\s*/i, '').replace(/```$/, '')); } catch { data = null; } }
      const s = steps(data);
      return s ? { ok: true, step: s, usage, model } : { ok: false, reason: 'invalid_output', message: 'The model did not return a step', usage, model };
    }
  };
}

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;
/** Claude through Anthropic's Messages API with native tool calling: a tool call is a step with its arguments, text is a
 *  reply. Its cost (micro-dollars) comes from the token counts and the prices of Program settings. */
export function claudeModel(o: { key: string; model: string; inUsdPerM: number; outUsdPerM: number; fetch?: Fetch; timeoutMs?: number }): AssistantModel {
  const f: Fetch = o.fetch ?? ((u, i) => fetch(u, i) as never);
  return {
    name: 'claude', service: 'claude',
    async step(system, turns, tools: ToolName[]): Promise<ModelResult> {
      const msgs: Array<{ role: 'user' | 'assistant'; content: string }> = [];
      for (const t of turns) {
        if (msgs.length && msgs[msgs.length - 1]!.role === t.role) msgs[msgs.length - 1]!.content += `\n${t.text}`;
        else msgs.push({ role: t.role, content: t.text });
      }
      while (msgs.length && msgs[0]!.role !== 'user') msgs.shift();
      const ask = { name: 'ask', description: 'Ask the staff member a question when a detail is missing or several things match', input_schema: { type: 'object', properties: { question: { type: 'string' }, options: { type: 'array', items: { type: 'string' } } }, required: ['question'] } };
      let j: { content?: Array<{ type: string; text?: string; name?: string; input?: Record<string, unknown> }>; usage?: { input_tokens?: number; output_tokens?: number }; error?: { message?: string } };
      let status = 0;
      try {
        const ctl = new AbortController(); const tm = setTimeout(() => ctl.abort(), o.timeoutMs ?? 20_000);
        const r = await f('https://api.anthropic.com/v1/messages', { method: 'POST', signal: ctl.signal, headers: { 'x-api-key': o.key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
          body: JSON.stringify({ model: o.model, max_tokens: 500, temperature: 0.1, system: system.replace(/\nAnswer with one JSON object:.*$/s, ''), tools: [...jsonSchemas(tools), ask], messages: msgs }) });
        clearTimeout(tm);
        status = r.status;
        j = (await r.json()) as typeof j;
        if (!r.ok) return { ok: false, reason: status === 429 || status === 529 ? 'quota' : 'unavailable', message: (j.error?.message ?? `HTTP ${status}`).slice(0, 200), model: o.model };
      } catch (e) {
        return { ok: false, reason: e instanceof Error && e.name === 'AbortError' ? 'timeout' : 'unavailable', message: e instanceof Error ? e.message.slice(0, 200) : 'failed', model: o.model };
      }
      const usd = ((j.usage?.input_tokens ?? 0) * o.inUsdPerM + (j.usage?.output_tokens ?? 0) * o.outUsdPerM) / 1_000_000;
      const usage = { units: Math.ceil(usd * 1_000_000), unit: 'microusd' as const };
      const call = j.content?.find((c) => c.type === 'tool_use');
      const said = j.content?.filter((c) => c.type === 'text').map((c) => c.text ?? '').join(' ').trim();
      if (call?.name === 'ask') return { ok: true, model: o.model, usage, step: { action: 'ask', question: String(call.input?.question ?? said ?? ''), options: (call.input?.options as string[] | undefined) ?? [] } };
      if (call?.name) return { ok: true, model: o.model, usage, step: { action: 'tool', tool: call.name, args: call.input ?? {} } };
      return { ok: true, model: o.model, usage, step: { action: 'reply', reply: said || 'I am not sure. Can you say it another way?' } };
    }
  };
}

// ---------------------------------------------------------------- the stub: deterministic, for local work and tests
const DATE = /(\d{4}-\d{2}-\d{2})/g;
/** The stub's step for the staff member's last message: a few phrasings for each tool, so the end-to-end tests drive
 *  every card. It answers with what the real model is told to: a tool and its arguments, a question, or a reply. */
export function fakeStep(text: string, tools: ToolName[]): Step {
  const t = text.trim();
  const l = t.toLowerCase();
  const has = (n: ToolName) => tools.includes(n);
  const dates = [...t.matchAll(DATE)].map((m) => m[1]!);
  const money = /\$\s?([\d,]+(?:\.\d{1,2})?)/.exec(t)?.[1]?.replace(/,/g, '');
  const after = (word: string) => new RegExp(`${word}\\s+(?:the\\s+)?([\\w .-]+?)(?:\\s+(?:to|on|for|at|is|from|now|\\?)\\b|[?.,]|$)`, 'i').exec(t)?.[1]?.trim();
  if (/\b(today|to do|needs doing|my tasks)\b/.test(l) && has('today')) return { action: 'tool', tool: 'today', args: {} };
  if (/\brecord\b.*\b(e-?transfer|cheque|cash|bank transfer)\b/.test(l) && has('record_payment')) {
    const method = /cheque/.test(l) ? 'cheque' : /cash/.test(l) ? 'cash' : /bank transfer/.test(l) ? 'bank_transfer' : 'e_transfer';
    return { action: 'tool', tool: 'record_payment', args: { invoice: /\b(INV-\d+)\b/i.exec(t)?.[1], booking: /\bbooking\s+([A-Z]-?\d+)/i.exec(t)?.[1], amount: money ? Number(money) : undefined, method,
      reference: /\b(?:ref(?:erence)?|#)\s*([A-Z0-9-]{3,})/i.exec(t)?.[1], received_on: dates[0] } };
  }
  if (/\b(who has|where is)\b/.test(l) && has('who_has_car')) return { action: 'tool', tool: 'who_has_car', args: { car: after('(?:who has|where is)') ?? '' } };
  if (/\b(free|available|availability)\b/.test(l) && dates.length >= 2 && has('availability')) {
    const car = /\bis (?:the )?(.+?) (?:free|available)/i.exec(t)?.[1];
    return { action: 'tool', tool: 'availability', args: { pickup_date: dates[0], return_date: dates[1], ...(car ? { car } : {}) } };
  }
  // what a renter owes on a booking (0133): a booking number with "owe"
  if (/\b(owe|owes|owing)\b/.test(l) && /\b[A-Z]-?\d{3,}\b/.test(t) && has('booking_balance')) return { action: 'tool', tool: 'booking_balance', args: { booking: /\b([A-Z]-?\d{3,})\b/.exec(t)![1] } };
  if (/\b(balance|owe|owes|owing)\b/.test(l) && has('owner_balance')) return { action: 'tool', tool: 'owner_balance', args: { owner: /(?:of|does|for)\s+([A-Z][\w'-]+(?: [A-Z][\w'-]+)*)/.exec(t)?.[1] ?? '' } };
  if (/^(find|look up|search)\b/.test(l) && has('find')) {
    const kind = /invoice|inv-/.test(l) ? 'invoice' : /\bowner\b/.test(l) ? 'owner' : /\brenter\b/.test(l) ? 'renter' : /\btoll|notice|ticket\b/.test(l) ? 'toll' : /\bcar\b/.test(l) ? 'car' : 'booking';
    return { action: 'tool', tool: 'find', args: { kind, q: t.replace(/^(find|look up|search)\s+(?:the\s+|a\s+)?(booking|renter|owner|car|invoice|toll notice|toll)?\s*/i, '').trim() || t } };
  }
  if (/\bpublish\b/.test(l) && has('publish_car')) return { action: 'tool', tool: 'publish_car', args: { car: after('publish') ?? '' } };
  if (/\b(rate|rates)\b/.test(l) && money && has('set_rates')) return { action: 'tool', tool: 'set_rates', args: { car: /(?:of|for) (?:the )?(.+?) to \$/i.exec(t)?.[1] ?? '', daily: Number(money) } };
  if (/payment link/.test(l) && has('send_payment_link')) return { action: 'tool', tool: 'send_payment_link', args: { booking: /\b([A-Z]-\d{3,})\b/.exec(t)?.[1], invoice: /\b(INV-\d+)\b/i.exec(t)?.[1] } };
  if (/\bconfirm\b.*\b(toll|notice)\b/.test(l) && has('confirm_toll')) return { action: 'tool', tool: 'confirm_toll', args: { toll: /\b(?:toll|notice)\s+([A-Z0-9-]{3,})/i.exec(t)?.[1] ?? '' } };
  if (/\b(task|remind)\b/.test(l) && has('create_task')) return { action: 'tool', tool: 'create_task', args: { title: (/task:?\s*(.+)$/i.exec(t)?.[1] ?? t).replace(/^to\s+/i, '').slice(0, 200) } };
  if (/\bdraft\b|\bwrite (a )?message\b/.test(l) && has('draft_message')) {
    const name = /\bto (?:renter |owner )?([A-Z][\w'-]+(?: [A-Z][\w'-]+)?)/.exec(t)?.[1] ?? 'there';
    const about = /\babout (.+)$/i.exec(t)?.[1] ?? 'your booking';
    return { action: 'tool', tool: 'draft_message', args: { to: /\bowner\b/.test(l) ? 'owner' : 'renter', name, text: `Hi ${name.split(' ')[0]}, this is CarmaCars about ${about.replace(/[.?!]+$/, '')}. Let us know if you have any questions. Thank you!` } };
  }
  if (/\b(send|make|create)\b.*\boffer\b/.test(l) && has('create_offer')) return { action: 'ask', question: 'Which car, the pickup and return (date and time), and the customer (a name, email or phone on file, or a new customer\'s name, email, mobile and date of birth)?', options: [] };
  if (/\b(add|new)\b.*\brental\b/.test(l) && has('add_rental')) return { action: 'ask', question: 'Which car, the pickup and return (date and time), and the renter\'s name, email and mobile?', options: [] };
  if (/\binsur/.test(l)) return { action: 'reply', reply: 'Marking a car insured is done on the car\'s page, not in the assistant yet.' };
  return { action: 'reply', reply: 'I can tell you what needs doing today, find bookings, renters, owners, cars and invoices, check which cars are free, and prepare changes for you to confirm. What do you need?' };
}

export function fakeModel(): AssistantModel {
  return {
    name: 'fake', service: 'workers_ai',
    async step(system, turns, tools): Promise<ModelResult> {
      if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
      if (process.env.FAKE_LLM_QUOTA === '1') return { ok: false, reason: 'quota', message: '4006: daily free allocation used' };
      const last = [...turns].reverse().find((x) => x.role === 'user')?.text ?? '';
      // a JSON step typed by a test is used as it is (the end-to-end tests drive every card this way)
      if (last.startsWith('{') && last.endsWith('}')) { try { return { ok: true, step: JSON.parse(last) as Step, usage: { units: 0, unit: 'neurons' }, model: 'fake-assistant-v1' }; } catch { /* a sentence */ } }
      return { ok: true, step: fakeStep(last, tools), usage: { units: Math.ceil(system.length / 40), unit: 'neurons' }, model: 'fake-assistant-v1' };
    }
  };
}
