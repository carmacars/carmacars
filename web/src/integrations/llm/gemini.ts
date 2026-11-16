import type { GenerateRequest, GenerateResult, TextGenerator } from './types';
import { jsonIn } from './workers-ai.ts';
import { geminiPost, type GeminiRelay } from '../photos/gemini-route.ts';

// r48 (3070): Google Gemini as the text model on the company's server when Workers AI has no token there
// (docs/hosting/off-cloudflare.md, section 2.2): the deploy needs no new secret, GEMINI_API_KEY is already set. JSON mode
// (responseMimeType application/json); the schema goes in the system text. A quota (429) or any refusal answers a
// failed result, never a throw, like the Workers AI adapter. A Workers AI model name (@cf/...) is not a Gemini model:
// the default is used then.
export const GEMINI_TEXT_DEFAULT = 'gemini-2.5-flash';

export function geminiModelFor(model: string | undefined, fallback = GEMINI_TEXT_DEFAULT): string {
  const m = (model ?? '').trim();
  return m && !m.startsWith('@cf/') && /^[a-z0-9][a-z0-9.\-]*$/i.test(m) ? m : fallback;
}

export function geminiText(apiKey: string, model = GEMINI_TEXT_DEFAULT, timeoutMs = 60_000, fetchImpl: typeof fetch = fetch, relay: GeminiRelay | null = null): TextGenerator {
  return {
    name: 'gemini',
    model,
    async generate<T>(req: GenerateRequest): Promise<GenerateResult<T>> {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const system = `${req.system}\nReply with one JSON object only, matching this JSON schema:\n${JSON.stringify(req.schema)}`;
        const { res, json } = await geminiPost({ apiKey, relay, fetch: fetchImpl, signal: ctl.signal }, `/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: 'user', parts: [{ text: req.prompt }] }],
          generationConfig: { temperature: req.temperature ?? 0.4, maxOutputTokens: req.maxOutputTokens, responseMimeType: 'application/json' }
        });
        if (res.status === 429) return { ok: false, reason: 'quota', message: 'Gemini quota reached' };
        if (!res.ok) return { ok: false, reason: 'unavailable', message: `Gemini answered ${res.status}` };
        const j = json as { candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>; usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number } } | null;
        const text = j?.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
        const usage = { inputTokens: j?.usageMetadata?.promptTokenCount ?? Math.ceil((system.length + req.prompt.length) / 4), outputTokens: j?.usageMetadata?.candidatesTokenCount ?? Math.ceil(text.length / 4), neurons: 0 };
        const data = jsonIn(text);
        if (!data || typeof data !== 'object' || Array.isArray(data)) return { ok: false, reason: 'invalid_output', message: 'Gemini did not answer one JSON object', usage };
        return { ok: true, data: data as T, model: `gemini:${model}`, usage };
      } catch (e) {
        if (e instanceof Error && e.name === 'AbortError') return { ok: false, reason: 'timeout', message: `Gemini did not answer within ${Math.round(timeoutMs / 1000)} seconds` };
        return { ok: false, reason: 'unavailable', message: 'Gemini could not be reached' };
      } finally {
        clearTimeout(t);
      }
    }
  };
}
