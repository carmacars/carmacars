// r48 (3030): where a Gemini call goes. Google refuses the Gemini API from some places ("User location is not supported for
// the API use", HTTP 400 FAILED_PRECONDITION), and the Cloudflare cron that runs the listing worker can start in any of
// Cloudflare's data centres, so some calls left from a refused place and every photo of that run failed. Now a call that is
// refused for its location is sent again through the relay on the company's server in Canada (Kong's /gemini/ route,
// infra/vps/supabase/volumes/api/kong.yml: only the service key passes it, Google sees the same API key), and the rest of
// that Worker's life goes straight to the relay. Without a relay (a local run) the refusal is answered as it came.
// Pure apart from fetch, which is passed in.

export const GEMINI_BASE = 'https://generativelanguage.googleapis.com';
export interface GeminiRelay { url: string; key: string }

let directRefused = false;
/** Tests: forget that the direct route was refused. */
export const resetGeminiRoute = () => { directRefused = false; };
export const geminiDirectRefused = () => directRefused;

/** A Gemini answer that refuses the place the call came from. */
export function isLocationRefusal(status: number, body: unknown): boolean {
  if (status !== 400 && status !== 403) return false;
  const e = (body as { error?: { message?: unknown; status?: unknown } } | null)?.error;
  return /location is not supported|not available in your (country|region)|unsupported_country|region is not supported/i.test(String(e?.message ?? ''));
}

/** The relay from the site's settings: the database API's address plus /gemini, with the service key. null when either is missing. */
export function relayFrom(supabaseUrl: string | null | undefined, serviceKey: string | null | undefined, override?: string | null): GeminiRelay | null {
  const base = (override ?? '').trim() || ((supabaseUrl ?? '').trim() ? `${supabaseUrl!.trim().replace(/\/+$/, '')}/gemini` : '');
  if (!base || !/^https?:\/\//.test(base) || !serviceKey) return null;
  return { url: base.replace(/\/+$/, ''), key: serviceKey };
}

/** POST to Gemini's `path` (for example /v1beta/models/x:generateContent): straight to Google, or through the relay once a
 *  call was refused for its location. Answers the Response and its parsed JSON body (null when not JSON). */
export async function geminiPost(o: { apiKey: string; relay?: GeminiRelay | null; fetch?: typeof fetch; signal?: AbortSignal }, path: string, body: unknown):
  Promise<{ res: Response; json: unknown; via: 'direct' | 'relay' }> {
  const f = o.fetch ?? fetch;
  const text = JSON.stringify(body);
  const send = async (via: 'direct' | 'relay') => {
    const url = via === 'relay' ? `${o.relay!.url}${path}` : `${GEMINI_BASE}${path}`;
    const headers: Record<string, string> = { 'content-type': 'application/json', 'x-goog-api-key': o.apiKey };
    if (via === 'relay') headers.apikey = o.relay!.key;
    const res = await f(url, { method: 'POST', signal: o.signal, headers, body: text });
    const json: unknown = await res.clone().json().catch(() => null);
    return { res, json, via };
  };
  if (directRefused && o.relay) return send('relay');
  const first = await send('direct');
  if (isLocationRefusal(first.res.status, first.json)) {
    directRefused = true;
    if (o.relay) return send('relay');
  }
  return first;
}
