import type { Transcriber, TranscribeRequest, TranscribeResult } from './types';

// Cloudflare Workers AI Whisper through the Worker's AI binding (wrangler.jsonc "ai": {"binding": "AI"}): no key, billed in
// neurons per minute of audio. whisper-large-v3-turbo takes the audio as base64 text; the older @cf/openai/whisper takes an
// array of bytes. Neurons per audio minute from the pricing page (developers.cloudflare.com/workers-ai/platform/pricing).
export const TRANSCRIBE_MODEL = '@cf/openai/whisper-large-v3-turbo';
export const NEURONS_PER_MINUTE: Record<string, number> = { '@cf/openai/whisper-large-v3-turbo': 46.63, '@cf/openai/whisper': 41.14, '@cf/openai/whisper-tiny-en': 41.14 };
export interface AiBinding { run(model: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<unknown> }

export function base64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function workersAiTranscriber(ai: AiBinding, timeoutMs = 45_000): Transcriber {
  return {
    name: 'workers-ai',
    async transcribe(req: TranscribeRequest): Promise<TranscribeResult> {
      const model = req.model || TRANSCRIBE_MODEL;
      const neurons = Math.ceil((Math.max(req.seconds, 1) / 60) * (NEURONS_PER_MINUTE[model] ?? 47));
      const input = /whisper-large|turbo/.test(model) ? { audio: base64(req.audio), language: 'en', vad_filter: true } : { audio: Array.from(req.audio) };
      let raw: unknown;
      try {
        raw = await Promise.race([
          ai.run(model, input),
          new Promise((_, no) => setTimeout(() => no(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), timeoutMs))
        ]);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof Error && e.name === 'TimeoutError') return { ok: false, reason: 'timeout', message: `Speech to text did not answer within ${Math.round(timeoutMs / 1000)} seconds`, model };
        if (/4006|neuron|allocation|429|3036|rate limit/i.test(msg)) return { ok: false, reason: 'quota', message: msg.slice(0, 300), model };
        return { ok: false, reason: 'unavailable', message: msg.slice(0, 300), model, neurons };
      }
      const text = (raw as { text?: unknown } | null)?.text;
      if (typeof text !== 'string') return { ok: false, reason: 'invalid_output', message: 'Speech to text returned no text', model, neurons };
      return { ok: true, text: text.replace(/\s+/g, ' ').trim(), model, neurons };
    }
  };
}
