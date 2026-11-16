import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { env } from '@/lib/env';
import { cachedRoutes, type ChainDeps, type Served } from './chain';
import { localReady, type LocalReady } from './ollama';

// r48 part AI (3095): what the chain (chain.ts) needs on the site: each feature's route (Admin > Settings > Usage, read once
// a minute), the record of which provider served each call (server_ai_served, never awaited), and the server's local
// models (infra/vps/ai) when they are ready with the pinned digest.
const SR = { role: 'service_role' as const };

export const LOCAL_DEFAULTS = { text: 'qwen2.5:3b', vision: 'qwen2.5vl:3b' } as const;

export function localConf() {
  const e = env();
  return {
    llmUrl: e.LOCAL_LLM_URL?.trim() || undefined,
    sttUrl: e.LOCAL_STT_URL?.trim() || undefined,
    textModel: e.LOCAL_LLM_MODEL?.trim() || LOCAL_DEFAULTS.text,
    visionModel: e.LOCAL_VISION_MODEL?.trim() || LOCAL_DEFAULTS.vision,
    textDigest: e.LOCAL_LLM_DIGEST?.trim() || undefined,
    visionDigest: e.LOCAL_VISION_DIGEST?.trim() || undefined
  };
}

let ready: { at: number; v: LocalReady } | null = null;
/** The local models ready now (read at most once a minute; a model still downloading, or with another digest, is not). */
export async function localNow(): Promise<LocalReady> {
  const c = localConf();
  if (!c.llmUrl && !c.sttUrl) return { text: false, vision: false, stt: false, textModel: null, visionModel: null, sttModel: null, detail: 'no local models on this host' };
  if (ready && Date.now() - ready.at < 60_000) return ready.v;
  const v = await localReady(c);
  ready = { at: Date.now(), v };
  return v;
}

const routes = cachedRoutes(async () => (await rpc('server_ai_routes' as never, {} as never, SR)) as unknown as Record<string, string> | null);

export function chainDeps(): ChainDeps {
  return {
    route: routes,
    served: (s: Served) => { void rpc('server_ai_served' as never, { p: s as unknown as Json } as never, SR).catch(() => undefined); }
  };
}
