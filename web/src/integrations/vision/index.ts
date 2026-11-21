import 'server-only';
import { env } from '@/lib/env';
import type { VisionModel } from './types';
import type { Provider } from '../ai/chain';
import { fakeVision, fallbackVision } from './fake';

// Every image read goes through the chain (r48 part AI, 3095; src/integrations/ai/chain.ts): Workers AI (the Worker's AI
// binding or its REST API; behind the usage guard), then the server's local vision model (Ollama, carmacars-llm), then
// Gemini (GEMINI_API_KEY) for car photos and other non-private images only: identity documents (licence_read,
// permit_read) are never sent to Gemini's free tier (the chain leaves it out for them). Without any link (a local server)
// or with LLM_PROVIDER=fake the fake answers; on the live site with no link, every read is unavailable (r48 security audit).
export async function visionModel(): Promise<VisionModel> {
  if (env().LLM_PROVIDER === 'fake') return fakeVision();
  const links: Partial<Record<Provider, VisionModel>> = {};
  try {
    const ai = await (await import('@/lib/platform/runtime')).aiBinding();
    if (ai) {
      const { workersAiVision } = await import('./workers-ai');
      // the toll notices and plates go through the usage guard too (0080, 0104)
      const [{ guardVision }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
      links.workers_ai = guardVision(workersAiVision(ai), aiRoom.paused, aiRoom.spent);
    }
  } catch { /* not running in the Worker */ }
  const { localNow, localConf, chainDeps } = await import('../ai/links');
  const c = localConf();
  if (c.llmUrl && (await localNow()).vision) {
    const [{ localVision }, { decodeImage, smallJpegDataUrl }] = await Promise.all([import('./local'), import('@/features/licence/barcode')]);
    // a smaller image is read in fewer image tokens (CPU time): 768 pixels on the long side
    const shrink = async (url: string) => {
      const img = decodeImage(Uint8Array.from(atob(url.replace(/^data:[^,]+,/, '')), (ch) => ch.charCodeAt(0)));
      return img ? smallJpegDataUrl(img, 768) : url;
    };
    links.local = localVision(c.llmUrl, c.visionModel, { shrink });
  }
  const key = env().GEMINI_API_KEY?.trim();
  if (key) {
    const [{ geminiVision, GEMINI_DEFAULT_MODEL }, { geminiRelay }] = await Promise.all([import('./gemini'), import('@/server/gemini-relay')]);
    // no neurons: not held by Workers AI's guard (it is the fallback when that allowance is used); 429 is its own quota
    links.gemini = geminiVision(key, env().GEMINI_VISION_MODEL || GEMINI_DEFAULT_MODEL, 30_000, fetch, geminiRelay());
  }
  // nothing connected: unavailable on the live site (a pickup check then says "not checked"), the fake locally
  if (!links.workers_ai && !links.local && !links.gemini) return fallbackVision(env().APP_ENV !== 'local');
  const { chainVision } = await import('../ai/chain');
  return chainVision(links, chainDeps());
}
export type * from './types';
