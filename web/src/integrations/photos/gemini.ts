// The image model for the showroom photos (release 35, features/listing/showroom.ts): Google AI Studio's image editing
// (generateContent with an image in and an image out). The key is the Worker's GEMINI_API_KEY, sent in a header (never in
// the address, so it is in no log); the model is Program settings' listing_showroom_ai_model. Pure apart from fetch, which
// is passed in (the unit tests use a fake). Every answer is mapped to a ShowroomOut: a quota (429), a model the key may
// not use, a refusal or any error is a failure the worker turns into the free local showroom, with the reason shown.
import type { ShowroomOut } from '../../features/listing/showroom.ts';
import { geminiPost, isLocationRefusal, type GeminiRelay } from './gemini-route.ts';

export const GEMINI_DEFAULT_MODEL = 'gemini-2.5-flash-image';

const b64 = (b: Uint8Array) => { let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => { const bin = atob(s); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; };

/** `relay` (r48, 3030): the company server's relay, used when Google refuses the place the call came from (gemini-route.ts). */
export interface GeminiOptions { apiKey: string; model?: string | null; fetch?: typeof fetch; timeoutMs?: number; relay?: GeminiRelay | null }

/** The image edited by the model, or why not. */
/** `extra`: more images after the first (1053: a photo of the real place of a marketing scene). */
export async function geminiEditImage(o: GeminiOptions, img: { bytes: Uint8Array; contentType: string }, prompt: string, extra: Array<{ bytes: Uint8Array; contentType: string }> = []): Promise<ShowroomOut> {
  const model = (o.model ?? '').trim() || GEMINI_DEFAULT_MODEL;
  if (!/^[a-z0-9][a-z0-9.-]{2,80}$/.test(model)) return { ok: false, reason: 'model', message: 'The model name is not valid' };
  const f = o.fetch ?? fetch;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), o.timeoutMs ?? 45_000);
  let res: Response;
  let raw: unknown;
  try {
    ({ res, json: raw } = await geminiPost({ apiKey: o.apiKey, relay: o.relay, fetch: f, signal: ctl.signal }, `/v1beta/models/${model}:generateContent`, {
      contents: [{ role: 'user', parts: [{ text: prompt }, { inline_data: { mime_type: img.contentType, data: b64(img.bytes) } },
        ...extra.map((x) => ({ inline_data: { mime_type: x.contentType, data: b64(x.bytes) } }))] }],
      generationConfig: { responseModalities: ['IMAGE'], imageConfig: { aspectRatio: '3:2' } }
    }));
  } catch (e) {
    const aborted = e instanceof Error && (e.name === 'AbortError' || /abort/i.test(e.message));
    return { ok: false, reason: aborted ? 'timeout' : 'error', message: aborted ? 'No answer in time' : 'The image model could not be reached' };
  } finally { clearTimeout(timer); }
  const body = raw as {
    error?: { message?: string; status?: string };
    candidates?: Array<{ finishReason?: string; content?: { parts?: Array<{ inlineData?: { mimeType?: string; data?: string }; inline_data?: { mime_type?: string; data?: string } }> } }>;
    promptFeedback?: { blockReason?: string };
  } | null;
  // r48: refused for the place the call came from (and no relay took it): a wait, never the photo's fault
  if (isLocationRefusal(res.status, body)) return { ok: false, reason: 'location', message: (body?.error?.message ?? 'User location is not supported').slice(0, 200) };
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

/** r45 (2840): the second pass on a made listing photo: several images in (the made photo first, then the originals), JSON
 *  out (features/listing/r45.ts checkPrompt). null on any refusal, quota or error: the photo is then not published. */
export const GEMINI_CHECK_MODEL = 'gemini-3.8-flash';
/** `fail` (REQ-005): told why no verdict came back (the HTTP status and Google's message, the finish reason of an answer
 *  without JSON, a timeout), so the call record carries the cause instead of a bare failure. */
export async function geminiCheckImages(o: GeminiOptions, images: Array<{ bytes: Uint8Array; contentType: string }>, system: string, prompt: string,
  fail: (why: string) => void = () => undefined): Promise<{ data: unknown; model: string } | null> {
  const model = (o.model ?? '').trim() || GEMINI_CHECK_MODEL;
  if (!/^[a-z0-9][a-z0-9.-]{2,80}$/.test(model) || !images.length) { fail(images.length ? 'model: the model name is not valid' : 'error: no image to check'); return null; }
  const f = o.fetch ?? fetch;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), o.timeoutMs ?? 45_000);
  try {
    const { res, json } = await geminiPost({ apiKey: o.apiKey, relay: o.relay, fetch: f, signal: ctl.signal }, `/v1beta/models/${model}:generateContent`, {
      systemInstruction: { parts: [{ text: system }] },
      contents: [{ role: 'user', parts: [{ text: prompt }, ...images.map((x) => ({ inline_data: { mime_type: x.contentType, data: b64(x.bytes) } }))] }],
      // 5080: room for a thinking model's own tokens (they count toward the limit; at 1200 an answer could be cut off and read as none)
      generationConfig: { temperature: 0, maxOutputTokens: 4096, responseMimeType: 'application/json' }
    });
    const j = json as { error?: { message?: string; status?: string }; promptFeedback?: { blockReason?: string };
      candidates?: Array<{ finishReason?: string; content?: { parts?: Array<{ text?: string }> } }> } | null;
    if (!res.ok) { fail(`http ${res.status}${j?.error?.status ? ` ${j.error.status}` : ''}: ${(j?.error?.message ?? '').slice(0, 200)}`); return null; }
    const text = j?.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
    const why = `no verdict: finish ${j?.candidates?.[0]?.finishReason ?? 'none'}${j?.promptFeedback?.blockReason ? `, blocked ${j.promptFeedback.blockReason}` : ''}, ${text.length} characters`;
    try {
      const data: unknown = JSON.parse(text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, ''));
      if (data && typeof data === 'object') return { data, model: `gemini:${model}` };
      fail(why); return null;
    } catch { fail(why); return null; }
  } catch (e) {
    fail(e instanceof Error && (e.name === 'AbortError' || /abort/i.test(e.message)) ? 'timeout: no answer in time' : 'error: the model could not be reached');
    return null;
  } finally { clearTimeout(timer); }
}
