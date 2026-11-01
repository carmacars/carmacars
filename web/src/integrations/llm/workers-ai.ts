import type { GenerateResult, TextGenerator, Usage } from './types';

// Cloudflare Workers AI through the Worker's AI binding (wrangler.jsonc "ai": {"binding": "AI"}): no key,
// billed in neurons, 10,000 a day free. JSON mode (response_format json_schema) on an instruct model.
// Neurons per million tokens from the pricing page (developers.cloudflare.com/workers-ai/platform/pricing).
export const DRAFT_MODEL = '@cf/meta/llama-3.3-70b-instruct-fp8-fast';
/** Live chat's model since 0370: about a sixth of the 70B's neurons a reply. It has no JSON mode: the reply is read
 *  from its text, and a reply that is not JSON is asked once more of the 70B model (JSON mode). */
export const CHAT_MODEL = '@cf/meta/llama-3.1-8b-instruct-fp8-fast';
const NEURONS_PER_M: Record<string, { input: number; output: number }> = {
  '@cf/meta/llama-3.3-70b-instruct-fp8-fast': { input: 26668, output: 204805 },
  '@cf/meta/llama-3.1-8b-instruct-fp8-fast': { input: 4119, output: 34868 },
  '@cf/meta/llama-3.1-8b-instruct': { input: 25608, output: 75147 },
  '@cf/meta/llama-3.2-3b-instruct': { input: 4625, output: 30475 }
};
/** The models with Workers AI's JSON mode (response_format json_schema); the others answer in text. */
const JSON_MODE = new Set(['@cf/meta/llama-3.3-70b-instruct-fp8-fast', '@cf/meta/llama-3-8b-instruct', '@cf/meta/llama-3.1-8b-instruct']);
export const hasJsonMode = (model: string) => JSON_MODE.has(model);

/** The first JSON object in a model's text (some models wrap it in prose or a code fence). */
export function jsonIn(text: string): unknown {
  const s = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```$/, '').trim();
  try { return JSON.parse(s); } catch { /* look for the object inside */ }
  const a = s.indexOf('{');
  if (a < 0) return undefined;
  let depth = 0, inStr = false, esc = false;
  for (let i = a; i < s.length; i++) {
    const ch = s[i];
    if (inStr) { if (esc) esc = false; else if (ch === '\\') esc = true; else if (ch === '"') inStr = false; continue; }
    if (ch === '"') inStr = true;
    else if (ch === '{') depth++;
    else if (ch === '}' && --depth === 0) { try { return JSON.parse(s.slice(a, i + 1)); } catch { return undefined; } }
  }
  return undefined;
}

export interface AiBinding {
  run(model: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<unknown>;
}

export function neuronsFor(model: string, inputTokens: number, outputTokens: number): number {
  const p = NEURONS_PER_M[model] ?? { input: 30000, output: 210000 };
  return Math.ceil((inputTokens * p.input + outputTokens * p.output) / 1_000_000);
}

export function workersAi(ai: AiBinding, model = DRAFT_MODEL, timeoutMs = 60_000): TextGenerator {
  model ||= DRAFT_MODEL;
  timeoutMs ||= 60_000;
  const one = async <T>(m: string, req: { system: string; prompt: string; schema: Record<string, unknown>; maxOutputTokens: number; temperature?: number }): Promise<GenerateResult<T>> => {
      const json = hasJsonMode(m);
      let raw: unknown;
      try {
        raw = await Promise.race([
          ai.run(m, {
            messages: [{ role: 'system', content: json ? req.system : `${req.system}\nReply with the JSON object only, no other text.` }, { role: 'user', content: req.prompt }],
            ...(json ? { response_format: { type: 'json_schema', json_schema: req.schema } } : {}),
            max_tokens: req.maxOutputTokens, temperature: req.temperature ?? 0.4
          }),
          new Promise((_, no) => setTimeout(() => no(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), timeoutMs))
        ]);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof Error && e.name === 'TimeoutError') return { ok: false, reason: 'timeout', message: `The model did not answer within ${Math.round(timeoutMs / 1000)} seconds` };
        // 4006: the daily free allocation is used up (Workers Free); 3036/429: rate limited
        if (/4006|neuron|allocation|429|3036|rate limit/i.test(msg)) return { ok: false, reason: 'quota', message: msg.slice(0, 300) };
        return { ok: false, reason: 'unavailable', message: msg.slice(0, 300) };
      }
      const r = (raw ?? {}) as { response?: unknown; usage?: { prompt_tokens?: number; completion_tokens?: number } };
      // the binding does not always report its token counts (the neurons of every call were recorded as 0 until the usage
      // guard, 0080): then they are estimated from the text, about 4 characters a token, so the daily gates count them
      const outText = typeof r.response === 'string' ? r.response : JSON.stringify(r.response ?? '');
      const usage: Usage = { inputTokens: r.usage?.prompt_tokens || Math.ceil((req.system.length + req.prompt.length) / 4),
        outputTokens: r.usage?.completion_tokens || Math.ceil(outText.length / 4), neurons: 0 };
      usage.neurons = neuronsFor(m, usage.inputTokens, usage.outputTokens);
      let data: unknown = r.response;
      if (typeof data === 'string') {
        data = jsonIn(data);
        if (data === undefined) return { ok: false, reason: 'invalid_output', message: 'The model did not return JSON', usage };
      }
      if (!data || typeof data !== 'object' || Array.isArray(data)) return { ok: false, reason: 'invalid_output', message: 'The model returned no object', usage };
      return { ok: true, data: data as T, model: m, usage };
  };
  return {
    name: 'workers-ai',
    model,
    async generate<T>(req: { system: string; prompt: string; schema: Record<string, unknown>; maxOutputTokens: number; temperature?: number }): Promise<GenerateResult<T>> {
      const r = await one<T>(model, req);
      // a model without JSON mode that wrote no JSON object: once more with the 70B model, which has it
      if (!r.ok && r.reason === 'invalid_output' && !hasJsonMode(model)) {
        const again = await one<T>(DRAFT_MODEL, req);
        const neurons = (r.usage?.neurons ?? 0) + (again.usage?.neurons ?? 0);
        const usage = again.usage ? { ...again.usage, neurons } : r.usage;
        return (usage ? { ...again, usage } : again) as GenerateResult<T>;
      }
      return r;
    }
  };
}
