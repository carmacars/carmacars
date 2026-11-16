// r48 part AI (migration 3095): the server's own models (infra/vps/ai): Ollama in the container carmacars-llm (a small text
// model and a small vision model, pinned by digest) and whisper.cpp in carmacars-stt. Free, private (nothing leaves the
// server) and slow (CPU only): the chain (chain.ts) asks them after Workers AI. Every failure is an answer, never a throw.
// Pure (fetch is passed in): the unit tests run it against a stand-in.

type Fetch = typeof fetch;
export type LocalFail = { ok: false; reason: 'timeout' | 'unavailable' | 'invalid_output'; message: string };
export type ChatOut = { ok: true; content: string; promptTokens: number; outputTokens: number; model: string } | LocalFail;

export interface OllamaChat {
  system: string;
  user: string;
  /** a conversation instead of one user message (the staff assistant): the earlier turns, the last one the newest */
  turns?: Array<{ role: 'user' | 'assistant'; content: string }>;
  /** base64 images (no data: prefix) for a vision model */
  images?: string[];
  /** a JSON schema (Ollama's structured outputs) or 'json' */
  format: Record<string, unknown> | 'json';
  maxTokens: number;
  temperature: number;
}

const WARMING = 'The server\'s local model is warming up (it is still downloading or loading): try again in a few minutes';

/** A schema Ollama can turn into a grammar: an object with properties. Anything else asks for plain JSON mode. */
export function formatFor(schema: Record<string, unknown> | undefined): Record<string, unknown> | 'json' {
  return schema && schema.type === 'object' && schema.properties && typeof schema.properties === 'object' ? schema : 'json';
}

/** One chat turn on Ollama (/api/chat, no streaming). A schema Ollama refuses is asked again in plain JSON mode. */
export async function ollamaChat(base: string, model: string, c: OllamaChat, timeoutMs: number, f: Fetch = fetch): Promise<ChatOut> {
  const ask = async (format: OllamaChat['format']): Promise<ChatOut | { refused: true }> => {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), timeoutMs);
    try {
      const r = await f(`${base.replace(/\/$/, '')}/api/chat`, {
        method: 'POST', signal: ctl.signal, headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          model, stream: false, keep_alive: '30m', format,
          messages: [{ role: 'system', content: c.system }, ...(c.turns?.length ? c.turns : [{ role: 'user', content: c.user, ...(c.images?.length ? { images: c.images } : {}) }])],
          options: { temperature: c.temperature, num_predict: c.maxTokens, num_ctx: 8192 }
        })
      });
      const j = (await r.json().catch(() => null)) as { message?: { content?: string }; prompt_eval_count?: number; eval_count?: number; error?: string } | null;
      if (r.status === 404 || /not found|pull/i.test(j?.error ?? '')) return { ok: false, reason: 'unavailable', message: WARMING };
      if (!r.ok) return format !== 'json' && r.status >= 400 && r.status < 500 ? { refused: true } : { ok: false, reason: 'unavailable', message: `The local model answered ${r.status}${j?.error ? `: ${j.error.slice(0, 160)}` : ''}` };
      const content = j?.message?.content ?? '';
      return { ok: true, content, promptTokens: j?.prompt_eval_count ?? Math.ceil((c.system.length + c.user.length) / 4), outputTokens: j?.eval_count ?? Math.ceil(content.length / 4), model: `local:${model}` };
    } catch (e) {
      if (e instanceof Error && e.name === 'AbortError') return { ok: false, reason: 'timeout', message: `The local model did not answer within ${Math.round(timeoutMs / 1000)} seconds` };
      return { ok: false, reason: 'unavailable', message: 'The local model is not reachable (its container is not running yet)' };
    } finally { clearTimeout(t); }
  };
  const first = await ask(c.format);
  if ('refused' in first) { const again = await ask('json'); return 'refused' in again ? { ok: false, reason: 'unavailable', message: 'The local model refused the request' } : again; }
  return first;
}

export interface LocalReady { text: boolean; vision: boolean; stt: boolean; textModel: string | null; visionModel: string | null; sttModel: string | null; detail: string }

/** What the local containers can answer now: Ollama's models present (by name and the pinned digest's first characters),
 *  whisper's server up. Used by the five-minute heartbeat (/api/jobs/ai-local) and the Admin's Usage page. */
export async function localReady(o: { llmUrl?: string; sttUrl?: string; textModel?: string; visionModel?: string; textDigest?: string; visionDigest?: string }, f: Fetch = fetch): Promise<LocalReady> {
  const out: LocalReady = { text: false, vision: false, stt: false, textModel: o.textModel ?? null, visionModel: o.visionModel ?? null, sttModel: null, detail: '' };
  const notes: string[] = [];
  const get = async (u: string) => {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 5000);
    try { return await f(u, { signal: ctl.signal }); } finally { clearTimeout(t); }
  };
  if (o.llmUrl) {
    try {
      const r = await get(`${o.llmUrl.replace(/\/$/, '')}/api/tags`);
      const j = (await r.json()) as { models?: Array<{ name?: string; model?: string; digest?: string }> };
      const has = (name?: string, digest?: string) => {
        if (!name) return false;
        const m = (j.models ?? []).find((x) => x.name === name || x.model === name || x.name === `${name}:latest`);
        return !!m && (!digest || (m.digest ?? '').startsWith(digest));
      };
      out.text = has(o.textModel, o.textDigest);
      out.vision = has(o.visionModel, o.visionDigest);
      if (!out.text) notes.push(`text model ${o.textModel ?? '?'} warming up`);
      if (!out.vision) notes.push(`vision model ${o.visionModel ?? '?'} warming up`);
    } catch { notes.push('carmacars-llm not reachable'); }
  } else notes.push('no local text model on this host');
  if (o.sttUrl) {
    try {
      // whisper.cpp's server listens only once its model is loaded (the container downloads and checks it first); its
      // /health answers 503 while loading, and an older build without /health answers 404: listening is ready
      const r = await get(`${o.sttUrl.replace(/\/$/, '')}/health`);
      out.stt = r.status !== 503 && r.status < 500;
      out.sttModel = 'whisper.cpp';
      if (!out.stt) notes.push('speech model warming up');
    } catch { notes.push('carmacars-stt not reachable'); }
  } else notes.push('no local speech model on this host');
  out.detail = notes.join('; ') || 'ready';
  return out;
}
