// The image model for the showroom photos (release 35, features/listing/showroom.ts): Google AI Studio's image editing
// (generateContent with an image in and an image out). The key is the Worker's GEMINI_API_KEY, sent in a header (never in
// the address, so it is in no log); the model is Program settings' listing_showroom_ai_model. Pure apart from fetch, which
// is passed in (the unit tests use a fake). Every answer is mapped to a ShowroomOut: a quota (429), a model the key may
// not use, a refusal or any error is a failure the worker turns into the free local showroom, with the reason shown.
import type { ShowroomOut } from '../../features/listing/showroom.ts';

export const GEMINI_DEFAULT_MODEL = 'gemini-2.5-flash-image';
const BASE = 'https://generativelanguage.googleapis.com/v1beta/models';

const b64 = (b: Uint8Array) => { let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => { const bin = atob(s); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };

export interface GeminiOptions { apiKey: string; model?: string | null; fetch?: typeof fetch; timeoutMs?: number }

/** The image edited by the model, or why not. */
/** `extra`: more images after the first (1053: a photo of the real place of a marketing scene). */
export async function geminiEditImage(o: GeminiOptions, img: { bytes: Uint8Array; contentType: string }, prompt: string, extra: Array<{ bytes: Uint8Array; contentType: string }> = []): Promise<ShowroomOut> {
  const model = (o.model ?? '').trim() || GEMINI_DEFAULT_MODEL;
  if (!/^[a-z0-9][a-z0-9.-]{2,80}$/.test(model)) return { ok: false, reason: 'model', message: 'The model name is not valid' };
  const f = o.fetch ?? fetch;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), o.timeoutMs ?? 45_000);
  let res: Response;
  try {
    res = await f(`${BASE}/${model}:generateContent`, {
      method: 'POST', signal: ctl.signal,
      headers: { 'content-type': 'application/json', 'x-goog-api-key': o.apiKey },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: prompt }, { inline_data: { mime_type: img.contentType, data: b64(img.bytes) } },
          ...extra.map((x) => ({ inline_data: { mime_type: x.contentType, data: b64(x.bytes) } }))] }],
        generationConfig: { responseModalities: ['IMAGE'], imageConfig: { aspectRatio: '3:2' } }
      })
    });
  } catch (e) {
    const aborted = e instanceof Error && (e.name === 'AbortError' || /abort/i.test(e.message));
    return { ok: false, reason: aborted ? 'timeout' : 'error', message: aborted ? 'No answer in time' : 'The image model could not be reached' };
  } finally { clearTimeout(timer); }
  const body = (await res.json().catch(() => null)) as {
    error?: { message?: string; status?: string };
    candidates?: Array<{ finishReason?: string; content?: { parts?: Array<{ inlineData?: { mimeType?: string; data?: string }; inline_data?: { mime_type?: string; data?: string } }> } }>;
    promptFeedback?: { blockReason?: string };
  } | null;
  if (!res.ok) {
    const status = body?.error?.status ?? '';
    const msg = (body?.error?.message ?? `HTTP ${res.status}`).slice(0, 200);
    if (res.status === 429 || status === 'RESOURCE_EXHAUSTED') return { ok: false, reason: 'quota', message: msg };
    if (res.status === 404 || res.status === 403 || status === 'NOT_FOUND' || status === 'PERMISSION_DENIED' || /model|not supported|billing|free tier/i.test(msg)) {
      return { ok: false, reason: 'model', message: msg };
    }
    if (res.status === 504 || status === 'DEADLINE_EXCEEDED') return { ok: false, reason: 'timeout', message: msg };
    return { ok: false, reason: 'error', message: msg };
  }
  for (const c of body?.candidates ?? []) {
    for (const p of c.content?.parts ?? []) {
      const d = p.inlineData ?? (p.inline_data ? { mimeType: p.inline_data.mime_type, data: p.inline_data.data } : null);
      if (d?.data && /^image\/(png|jpeg)$/.test(d.mimeType ?? '')) return { ok: true, bytes: unb64(d.data), contentType: d.mimeType!, provider: 'ai', model };
    }
  }
  return { ok: false, reason: 'blocked', message: body?.promptFeedback?.blockReason ?? body?.candidates?.[0]?.finishReason ?? 'No image in the answer' };
}
