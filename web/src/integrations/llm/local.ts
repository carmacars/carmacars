import type { GenerateRequest, GenerateResult, TextGenerator } from './types';
import { jsonIn } from './workers-ai.ts';
import { formatFor, ollamaChat } from '../ai/ollama.ts';

// r48 part AI (3095): the server's local text model (Ollama in carmacars-llm; Qwen2.5 3B Instruct, Q4_K_M, pinned by digest
// in infra/vps/ai/models.env) for chat, auto-replies, listing copy and the other text tasks when Workers AI is unavailable
// or over its allowance. No neurons: it costs nothing and is never counted against Workers AI's allowance. CPU only, so a
// call may take tens of seconds: its timeout is at least LOCAL_MIN_TIMEOUT_MS (60 s), whatever the caller asked of Workers AI.
export const LOCAL_MIN_TIMEOUT_MS = 60_000;

export function localText(base: string, model: string, timeoutMs = LOCAL_MIN_TIMEOUT_MS, f: typeof fetch = fetch): TextGenerator {
  const wait = Math.max(timeoutMs || 0, LOCAL_MIN_TIMEOUT_MS);
  return {
    name: 'local',
    model: `local:${model}`,
    async generate<T>(req: GenerateRequest): Promise<GenerateResult<T>> {
      const r = await ollamaChat(base, model, {
        system: `${req.system}\nReply with one JSON object only.`, user: req.prompt, format: formatFor(req.schema),
        maxTokens: req.maxOutputTokens, temperature: req.temperature ?? 0.4
      }, wait, f);
      if (!r.ok) return r;
      const usage = { inputTokens: r.promptTokens, outputTokens: r.outputTokens, neurons: 0 };
      const data = jsonIn(r.content);
      if (!data || typeof data !== 'object' || Array.isArray(data)) return { ok: false, reason: 'invalid_output', message: 'The local model did not answer one JSON object', usage };
      return { ok: true, data: data as T, model: r.model, usage };
    }
  };
}
