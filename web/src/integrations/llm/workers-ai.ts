import type { GenerateResult, TextGenerator, Usage } from './types';

// Cloudflare Workers AI through the Worker's AI binding (wrangler.jsonc "ai": {"binding": "AI"}): no key,
// billed in neurons, 10,000 a day free. JSON mode (response_format json_schema) on an instruct model.
// Neurons per million tokens from the pricing page (developers.cloudflare.com/workers-ai/platform/pricing).
export const DRAFT_MODEL = '@cf/meta/llama-3.3-70b-instruct-fp8-fast';
const NEURONS_PER_M: Record<string, { input: number; output: number }> = {
  '@cf/meta/llama-3.3-70b-instruct-fp8-fast': { input: 26668, output: 204805 }
};

export interface AiBinding {
  run(model: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<unknown>;
}

export function neuronsFor(model: string, inputTokens: number, outputTokens: number): number {
  const p = NEURONS_PER_M[model] ?? { input: 30000, output: 210000 };
  return Math.ceil((inputTokens * p.input + outputTokens * p.output) / 1_000_000);
}

export function workersAi(ai: AiBinding, model = DRAFT_MODEL, timeoutMs = 60_000): TextGenerator {
  return {
    name: 'workers-ai',
    model,
    async generate<T>(req: { system: string; prompt: string; schema: Record<string, unknown>; maxOutputTokens: number; temperature?: number }): Promise<GenerateResult<T>> {
      let raw: unknown;
      try {
        raw = await Promise.race([
          ai.run(model, {
            messages: [{ role: 'system', content: req.system }, { role: 'user', content: req.prompt }],
            response_format: { type: 'json_schema', json_schema: req.schema },
            max_tokens: req.maxOutputTokens, temperature: req.temperature ?? 0.4
          }),
          new Promise((_, no) => setTimeout(() => no(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), timeoutMs))
        ]);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof Error && e.name === 'TimeoutError') return { ok: false, reason: 'timeout', message: 'The model did not answer within 60 seconds' };
        // 4006: the daily free allocation is used up (Workers Free); 3036/429: rate limited
        if (/4006|neuron|allocation|429|3036|rate limit/i.test(msg)) return { ok: false, reason: 'quota', message: msg.slice(0, 300) };
        return { ok: false, reason: 'unavailable', message: msg.slice(0, 300) };
      }
      const r = (raw ?? {}) as { response?: unknown; usage?: { prompt_tokens?: number; completion_tokens?: number } };
      const usage: Usage = { inputTokens: r.usage?.prompt_tokens ?? 0, outputTokens: r.usage?.completion_tokens ?? 0, neurons: 0 };
      usage.neurons = neuronsFor(model, usage.inputTokens, usage.outputTokens);
      let data: unknown = r.response;
      if (typeof data === 'string') {
        const s = data.trim().replace(/^```(?:json)?\s*/i, '').replace(/```$/, '');
        try { data = JSON.parse(s); } catch { return { ok: false, reason: 'invalid_output', message: 'The model did not return JSON', usage }; }
      }
      if (!data || typeof data !== 'object' || Array.isArray(data)) return { ok: false, reason: 'invalid_output', message: 'The model returned no object', usage };
      return { ok: true, data: data as T, model, usage };
    }
  };
}
