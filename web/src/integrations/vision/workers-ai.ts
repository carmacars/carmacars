import type { VisionModel, VisionRequest, VisionResult, VisionUsage } from './types';

// Cloudflare Workers AI vision models through the Worker's AI binding (wrangler.jsonc "ai"). The image goes as a
// data URL in the chat message (the OpenAI shape Workers AI accepts); a model that wants the image on its own
// ("image") is asked that way. Meta's Llama 3.2 vision model needs its licence accepted once: the adapter sends
// "agree" when the answer says so, then asks again. Neurons per million tokens from the pricing page
// (developers.cloudflare.com/workers-ai/platform/pricing).
const NEURONS_PER_M: Record<string, { input: number; output: number }> = {
  '@cf/meta/llama-4-scout-17b-16e-instruct': { input: 24545, output: 77273 },
  '@cf/meta/llama-3.2-11b-vision-instruct': { input: 4410, output: 61493 },
  '@cf/mistralai/mistral-small-3.1-24b-instruct': { input: 31876, output: 50488 },
  '@cf/google/gemma-3-12b-it': { input: 31371, output: 50560 }
};
export interface AiBinding { run(model: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<unknown> }

export function neuronsFor(model: string, u: { inputTokens: number; outputTokens: number }): number {
  const p = NEURONS_PER_M[model] ?? { input: 30000, output: 80000 };
  return Math.ceil((u.inputTokens * p.input + u.outputTokens * p.output) / 1_000_000);
}

/** The first JSON object in a model's text (it may wrap it in a code fence or a sentence). */
export function jsonFrom(raw: unknown): unknown {
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string') return null;
  const s = raw.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  try { return JSON.parse(s); } catch { /* look for the object inside */ }
  const a = s.indexOf('{'), b = s.lastIndexOf('}');
  if (a >= 0 && b > a) { try { return JSON.parse(s.slice(a, b + 1)); } catch { return null; } }
  return null;
}

type Attempt = 'chat_schema' | 'chat' | 'image_field';
export function workersAiVision(ai: AiBinding, timeoutMs = 45_000): VisionModel {
  const call = (model: string, input: Record<string, unknown>) => Promise.race([
    ai.run(model, input),
    new Promise((_, no) => setTimeout(() => no(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), timeoutMs))
  ]);
  const input = (req: VisionRequest, how: Attempt): Record<string, unknown> => {
    if (how === 'image_field') {
      return { messages: [{ role: 'system', content: req.system }, { role: 'user', content: req.prompt }], image: req.imageDataUrl.replace(/^data:[^,]+,/, ''), max_tokens: req.maxOutputTokens, temperature: 0 };
    }
    return {
      messages: [{ role: 'system', content: req.system }, { role: 'user', content: [{ type: 'text', text: req.prompt }, { type: 'image_url', image_url: { url: req.imageDataUrl } }] }],
      max_tokens: req.maxOutputTokens, temperature: 0,
      ...(how === 'chat_schema' && req.schema ? { response_format: { type: 'json_schema', json_schema: req.schema } } : {})
    };
  };
  return {
    name: 'workers-ai',
    async read(req, models) {
      const tried: string[] = [];
      let last: VisionResult = { ok: false, reason: 'unavailable', message: 'No vision model is set in Program settings', tried };
      for (const model of models.filter(Boolean)) {
        tried.push(model);
        let agreed = false;
        const plan: Attempt[] = req.schema ? ['chat_schema', 'chat', 'image_field'] : ['chat', 'image_field'];
        for (let i = 0; i < plan.length; i++) {
          let raw: unknown;
          try {
            raw = await call(model, input(req, plan[i]!));
          } catch (e) {
            const msg = e instanceof Error ? e.message : String(e);
            if (e instanceof Error && e.name === 'TimeoutError') { last = { ok: false, reason: 'timeout', message: `${model} did not answer within ${Math.round(timeoutMs / 1000)} seconds`, model, tried }; break; }
            if (/4006|neuron|allocation|daily free|429|3036|rate limit/i.test(msg)) return { ok: false, reason: 'quota', message: msg.slice(0, 300), model, tried };
            // the licence of Meta's vision model is accepted once per account by sending "agree"
            if (!agreed && /agree|licen[cs]e|5016/i.test(msg)) { agreed = true; await call(model, { prompt: 'agree' }).catch(() => undefined); i--; continue; }
            // not on this account: the next model
            if (/5007|no such model|not found|unknown model|invalid model/i.test(msg)) { last = { ok: false, reason: 'unavailable', message: msg.slice(0, 300), model, tried }; break; }
            // the input shape was refused: the next shape
            last = { ok: false, reason: 'unavailable', message: msg.slice(0, 300), model, tried };
            continue;
          }
          const r = (raw ?? {}) as { response?: unknown; usage?: { prompt_tokens?: number; completion_tokens?: number } };
          const text = typeof r.response === 'string' ? r.response : JSON.stringify(r.response ?? '');
          const usage: VisionUsage = { inputTokens: r.usage?.prompt_tokens ?? Math.ceil((req.prompt.length + req.system.length) / 4) + 1600, outputTokens: r.usage?.completion_tokens ?? Math.ceil(text.length / 4), neurons: 0 };
          usage.neurons = neuronsFor(model, usage);
          const data = jsonFrom(r.response);
          if (data && typeof data === 'object') return { ok: true, data, model, usage, tried };
          last = { ok: false, reason: 'invalid_output', message: `${model} did not answer in JSON`, model, usage, tried };
        }
      }
      return last;
    }
  };
}
