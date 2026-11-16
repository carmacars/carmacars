import type { GenerateRequest, GenerateResult, TextGenerator } from '../llm/types.ts';
import type { VisionModel, VisionRequest, VisionResult } from '../vision/types.ts';
import type { Transcriber, TranscribeRequest, TranscribeResult } from '../transcribe/types.ts';
import { TASK_PURPOSE } from './guard.ts';

// r48 part AI (migration 3095): every AI call of the site goes through one chain, so each feature keeps working at no cost
// once the site runs on the company's server (docs/hosting/off-cloudflare.md, section 2.2):
//   1. Workers AI (the free 10,000 neurons a day, behind the usage guard: guard.ts)
//   2. the local models on the server (Ollama: a small text model and a small vision model; whisper.cpp for speech)
//   3. Gemini's free tier, for what is not private only (never identity documents, recordings, call or interview text)
// A link that answers quota, unavailable, timeout or invalid output hands the call to the next one. Admin > Settings >
// Usage sets the order per feature (the route) and shows which provider served each call, with a 7-day count.
// Pure: the providers, the route and the record of each call are passed in (index.ts of each integration builds them).

export type Provider = 'workers_ai' | 'local' | 'gemini';
export type Route = 'auto' | 'no_gemini' | 'local_first' | 'workers_ai_only' | 'local_only';
export const ROUTES: readonly Route[] = ['auto', 'no_gemini', 'local_first', 'workers_ai_only', 'local_only'];

/** Never sent to Gemini's free tier (Google may use free-tier requests): a person's identity documents, the recordings, and
 *  the text made from them (call summaries, interview follow-ups and scores). */
export const PRIVATE_PURPOSES: ReadonlySet<string> = new Set(['licence_read', 'permit_read', 'interview_transcribe', 'call_transcribe', 'phone_summary', 'interview_followup', 'interview_score']);

/** The providers a purpose is asked, in order, for a route. */
export function providerOrder(route: Route | string | null | undefined, purpose: string): Provider[] {
  const r: Provider[] = route === 'no_gemini' ? ['workers_ai', 'local'] : route === 'local_first' ? ['local', 'workers_ai', 'gemini']
    : route === 'workers_ai_only' ? ['workers_ai'] : route === 'local_only' ? ['local'] : ['workers_ai', 'local', 'gemini'];
  return PRIVATE_PURPOSES.has(purpose) ? r.filter((p) => p !== 'gemini') : r;
}

/** One served (or failed) call, for Admin > Settings > Usage (server_ai_served). provider 'none': no link could answer. */
export interface Served { purpose: string; provider: Provider | 'none'; ok: boolean; reason?: string | null; ms: number; model?: string | null }

export interface ChainDeps {
  /** The route of a purpose (Admin > Settings > Usage); 'auto' when it cannot be read. */
  route(purpose: string): Promise<Route>;
  /** Records a call; never awaited by the caller's answer, never throws. */
  served(s: Served): void;
  now?: () => number;
}

type Fail = { ok: false; reason: string; message: string };
const PASS_ON = new Set(['quota', 'unavailable', 'timeout', 'invalid_output']);

/** Runs a call down the chain: the first link that answers wins. With no answer: the quota refusal if any link gave one
 *  (callers then wait for the allowance, nothing is counted), else the last failure. */
async function run<R extends { ok: boolean }>(purpose: string, links: Partial<Record<Provider, unknown>>, deps: ChainDeps, call: (p: Provider) => Promise<R>, none: () => R, modelOf: (r: R) => string | null): Promise<R> {
  const now = deps.now ?? Date.now;
  const route = await deps.route(purpose).catch(() => 'auto' as Route);
  const order = providerOrder(route, purpose).filter((p) => links[p]);
  let last: R | null = null, quota: R | null = null;
  for (const p of order) {
    const t0 = now();
    let r: R;
    try { r = await call(p); } catch (e) { r = { ok: false, reason: 'unavailable', message: e instanceof Error ? e.message.slice(0, 200) : 'failed' } as unknown as R; }
    const f = r as unknown as Fail;
    try { deps.served({ purpose, provider: p, ok: r.ok, reason: r.ok ? null : f.reason, ms: Math.max(0, now() - t0), model: modelOf(r) }); } catch { /* the record never stops a call */ }
    if (r.ok) return r;
    last = r;
    if (f.reason === 'quota' && !quota) quota = r;
    if (!PASS_ON.has(f.reason)) break;
  }
  if (!order.length) { try { deps.served({ purpose, provider: 'none', ok: false, reason: 'unavailable', ms: 0 }); } catch { /* ignore */ } }
  return quota ?? last ?? none();
}

const NONE_MSG = 'No AI provider is connected for this feature (Workers AI, the server\'s local model or Gemini)';

export function chainText(links: Partial<Record<Provider, TextGenerator>>, deps: ChainDeps): TextGenerator {
  const first = (['workers_ai', 'local', 'gemini'] as const).map((p) => links[p]).find(Boolean);
  return {
    name: first?.name ?? 'fake',
    model: first?.model ?? 'none',
    generate<T>(req: GenerateRequest): Promise<GenerateResult<T>> {
      const purpose = TASK_PURPOSE[req.task] ?? req.task;
      return run<GenerateResult<T>>(purpose, links, deps, (p) => links[p]!.generate<T>(req), () => ({ ok: false, reason: 'unavailable', message: NONE_MSG }), (r) => (r.ok ? r.model : null));
    }
  };
}

export function chainVision(links: Partial<Record<Provider, VisionModel>>, deps: ChainDeps): VisionModel {
  const first = (['workers_ai', 'local', 'gemini'] as const).map((p) => links[p]).find(Boolean);
  return {
    name: first?.name ?? 'fake',
    read(req: VisionRequest, models: string[]): Promise<VisionResult> {
      const tried: string[] = [];
      return run<VisionResult>(req.purpose, links, deps, async (p) => {
        const r = await links[p]!.read(req, models);
        tried.push(...r.tried);
        return { ...r, tried: [...tried] };
      }, () => ({ ok: false, reason: 'unavailable', message: NONE_MSG, tried }), (r) => r.model ?? null);
    }
  };
}

export function chainTranscriber(links: Partial<Record<Provider, Transcriber>>, deps: ChainDeps, purpose: string): Transcriber {
  const first = (['workers_ai', 'local'] as const).map((p) => links[p]).find(Boolean);
  // speech is never sent to Gemini: only Workers AI and the local whisper are links
  const safe: Partial<Record<Provider, Transcriber>> = { workers_ai: links.workers_ai, local: links.local };
  return {
    name: first?.name ?? 'fake',
    transcribe(req: TranscribeRequest): Promise<TranscribeResult> {
      return run<TranscribeResult>(purpose, safe, deps, (p) => safe[p]!.transcribe(req),
        () => ({ ok: false, reason: 'unavailable', message: 'Speech to text is not connected on this server (no Workers AI and the local speech model is not ready)' }), (r) => r.model ?? null);
    }
  };
}

/** The routes read once a minute (server_ai_routes); a route that cannot be read is 'auto'. */
export function cachedRoutes(read: () => Promise<Record<string, string> | null>, ttlMs = 60_000, now: () => number = Date.now): (purpose: string) => Promise<Route> {
  let at = -Infinity;
  let map: Record<string, string> = {};
  return async (purpose) => {
    if (now() - at >= ttlMs) { map = (await read().catch(() => null)) ?? {}; at = now(); }
    const r = map[purpose];
    return (ROUTES as readonly string[]).includes(r ?? '') ? (r as Route) : 'auto';
  };
}
