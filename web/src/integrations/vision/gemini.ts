import type { VisionModel, VisionRequest, VisionResult } from './types';

// Google Gemini as a second vision provider (release 35, migration 0910), used only when GEMINI_API_KEY is set and only as
// the fallback of Workers AI. The key is on the free trial tier for now: a quota (429), a model the key may not use (403,
// 404) or any other error answers "not read" silently, and the person types the reading. The image goes inline; the answer
// is JSON. Swappable: the reader asks any VisionModel.
const BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
export const GEMINI_DEFAULT_MODEL = 'gemini-2.0-flash';

export function geminiVision(apiKey: string, model: string = GEMINI_DEFAULT_MODEL, timeoutMs = 30_000, fetchImpl: typeof fetch = fetch): VisionModel {
  return {
    name: 'gemini',
    async read(req: VisionRequest): Promise<VisionResult> {
      const tried = [`gemini:${model}`];
      const m = /^data:(image\/(?:jpeg|png));base64,(.+)$/.exec(req.imageDataUrl);
      if (!m) return { ok: false, reason: 'invalid_output', message: 'The image is not a JPEG or PNG data URL', tried };
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const r = await fetchImpl(`${BASE}/${encodeURIComponent(model)}:generateContent`, {
          method: 'POST', signal: ctl.signal,
          headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: req.system }] },
            contents: [{ role: 'user', parts: [{ text: req.prompt }, { inline_data: { mime_type: m[1], data: m[2] } }] }],
            generationConfig: { temperature: 0, maxOutputTokens: req.maxOutputTokens, responseMimeType: 'application/json' }
          })
        });
        if (r.status === 429) return { ok: false, reason: 'quota', message: 'Gemini quota reached', tried };
        if (!r.ok) return { ok: false, reason: 'unavailable', message: `Gemini answered ${r.status}`, tried };
        const j = (await r.json().catch(() => null)) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>; usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number } } | null;
        const text = j?.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
        let data: unknown = null;
        try { data = JSON.parse(text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '')); } catch { data = null; }
        const usage = { inputTokens: j?.usageMetadata?.promptTokenCount ?? 0, outputTokens: j?.usageMetadata?.candidatesTokenCount ?? 0, neurons: 0 };
        if (!data || typeof data !== 'object') return { ok: false, reason: 'invalid_output', message: 'Gemini did not answer in JSON', usage, tried };
        return { ok: true, data, model: `gemini:${model}`, usage, tried };
      } catch (e) {
        return { ok: false, reason: e instanceof Error && e.name === 'AbortError' ? 'timeout' : 'unavailable', message: 'Gemini could not be reached', tried };
      } finally {
        clearTimeout(t);
      }
    }
  };
}
