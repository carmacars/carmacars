// r48 part AI: the visitor chat and the staff assistant answer with the server's local model (deploy-vps, job node-smoke):
// Ollama in its container with the pinned text model (infra/vps/ai/models.env), the site's own prompts and agents
// (src/features/chat/agent.ts, src/features/assistant/agent.ts), stand-ins for the database. Each must come back with a
// real answer from the local model (not a hand-off for a model failure), within the local model's timeouts.
//   LOCAL_LLM_URL=http://127.0.0.1:11434 LOCAL_LLM_MODEL=qwen2.5:3b node --experimental-strip-types scripts/ai-local-smoke.mjs
import { localText } from '../src/integrations/llm/local.ts';
import { localModel } from '../src/features/assistant/models.ts';
import { runAgent, STEP_SCHEMA } from '../src/features/chat/agent.ts';
import { ask } from '../src/features/assistant/agent.ts';

const URL_ = process.env.LOCAL_LLM_URL || 'http://127.0.0.1:11434';
const MODEL = process.env.LOCAL_LLM_MODEL || 'qwen2.5:3b';
const problems = [];
const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

// ------------------------------------------------------------------ the visitor chat
const gen = localText(URL_, MODEL, 120_000);
const facts = {
  today, weekday: new Date().toLocaleDateString('en-CA', { weekday: 'long', timeZone: 'America/Toronto' }),
  site: { brand: 'CarmaCars', city: 'Toronto', phone: '+1 647 000 0000', hours: '9 am to 9 pm', reply: 'within minutes', service_area: 'Greater Toronto Area' },
  rules: { min_age: 21, standard_min_age: 25, max_days: 30, licences: ['G'], notice_minutes: 120, deposit_release_days: 7 },
  fleet: [{ slug: 'mercedes-benz-c300', name: '2023 Mercedes-Benz C 300', class: 'luxury', seats: 5, transmission: 'automatic', fuel: 'gasoline', daily_rate_cents: 12900, deposit_cents: 50000, vehicle_id: '00000000-0000-0000-0000-000000000001' }],
  never_say: []
};
const t0 = Date.now();
const chat = await runAgent({
  facts,
  model: async (system, prompt) => {
    const r = await gen.generate({ task: 'chat', system, prompt, schema: STEP_SCHEMA, maxOutputTokens: 300, temperature: 0.2 });
    return r.ok ? { ok: true, data: r.data, usage: r.usage, model: r.model } : { ok: false, reason: r.reason, message: r.message, usage: r.usage };
  },
  quote: async () => ({ available: true, total_cents: 25800, deposit_cents: 50000, billable_days: 2 }),
  search: async () => [],
  lead: async () => ({ ok: true, reference: 'L-1' }),
  instant: (d, t) => `${d}T${t}:00-05:00`
}, { history: [], text: 'Hi, I am in Toronto next week for a wedding. Which of your cars would you suggest for that?' });
console.log(`chat (${Math.round((Date.now() - t0) / 1000)} s, ${chat.model ?? '?'}): ${chat.reply ?? `handoff: ${chat.handoff?.reason ?? chat.error}`}`);
if (!chat.ok || !(chat.model ?? '').startsWith('local:')) problems.push(`chat: the local model did not answer (${chat.error ?? 'no model'})`);
else if (!chat.reply && !chat.handoff) problems.push('chat: neither a reply nor a hand-off');

// ------------------------------------------------------------------ the staff assistant
const t1 = Date.now();
const recorded = [];
const out = await ask({
  who: { portal: 'admin', fn: null }, today, name: 'Smoke', model: localModel(URL_, MODEL, { timeoutMs: 180_000 }),
  gate: async () => ({ ok: true, service: 'local' }),
  record: async (u) => { recorded.push(u); },
  todo: async () => [{ type: 'results', title: '2 things need you', rows: [{ title: 'Approve booking B-1001', href: '/admin' }], empty: '' }],
  find: async () => [], available: async () => [],
  propose: async (p) => ({ id: 'p1', summary: p.summary })
}, { text: 'What do I need to do today?' });
const said = out.out.map((o) => o.text ?? o.title ?? '').join(' | ');
console.log(`assistant (${Math.round((Date.now() - t1) / 1000)} s, ${recorded[0]?.model ?? '?'}): ${said}`);
if (!recorded[0]?.ok) problems.push(`assistant: the local model did not answer (${recorded[0]?.error ?? 'no step'})`);
if (!out.out.length || out.out.some((o) => o.type === 'paused')) problems.push('assistant: no answer');

if (problems.length) {
  for (const p of problems) console.log(`::error title=local model smoke::${p}`);
  process.exit(1);
}
console.log('local model smoke: passed');
