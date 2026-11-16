import type { VisionModel, VisionRequest, VisionResult } from './types';
import { jsonFrom } from './workers-ai.ts';
import { formatFor, ollamaChat } from '../ai/ollama.ts';

// r48 part AI (3095): the server's local vision model (Ollama in carmacars-llm; Qwen2.5-VL 3B, pinned by digest) for the
// photo checks, plate checks and the other image reads when Workers AI is unavailable or over its allowance. It runs on
// the server: identity documents may be read here (nothing leaves the machine). No neurons. CPU only: a photo takes about
// half a minute, so its timeout is at least 90 seconds. The image may be made smaller first (shrink, passed in) so the
// model reads fewer image tokens.
export const LOCAL_VISION_TIMEOUT_MS = 90_000;

export function localVision(base: string, model: string, o: { timeoutMs?: number; shrink?: (dataUrl: string) => Promise<string>; fetch?: typeof fetch } = {}): VisionModel {
  const wait = Math.max(o.timeoutMs ?? 0, LOCAL_VISION_TIMEOUT_MS);
  return {
    name: 'local',
    async read(req: VisionRequest): Promise<VisionResult> {
      const tried = [`local:${model}`];
      const url = o.shrink ? await o.shrink(req.imageDataUrl).catch(() => req.imageDataUrl) : req.imageDataUrl;
      const b64 = url.replace(/^data:[^,]+,/, '');
      if (!b64) return { ok: false, reason: 'invalid_output', message: 'No image to read', tried };
      const r = await ollamaChat(base, model, {
        system: `${req.system}\nReply with one JSON object only.`, user: req.prompt, images: [b64], format: formatFor(req.schema),
        maxTokens: req.maxOutputTokens, temperature: 0
      }, wait, o.fetch ?? fetch);
      if (!r.ok) return { ...r, model: `local:${model}`, tried };
      const usage = { inputTokens: r.promptTokens, outputTokens: r.outputTokens, neurons: 0 };
      const data = jsonFrom(r.content);
      if (!data || typeof data !== 'object') return { ok: false, reason: 'invalid_output', message: 'The local vision model did not answer in JSON', model: r.model, usage, tried };
      return { ok: true, data, model: r.model, usage, tried };
    }
  };
}
