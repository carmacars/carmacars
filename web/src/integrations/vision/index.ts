import 'server-only';
import { env } from '@/lib/env';
import type { VisionModel } from './types';
import { fakeVision } from './fake';

// LLM_PROVIDER=workers-ai (production) uses the Worker's AI binding or Workers AI's REST API; r48 (3070): on the company's
// server without a Workers AI token, Gemini (GEMINI_API_KEY), except for identity documents. Without either (a local server) or with LLM_PROVIDER=fake
// the fake answers.
/** What Gemini never reads (driver's licences and ownership permits carry a person's identity). */
const PERSONAL = new Set(['licence_read', 'permit_read']);

export async function visionModel(): Promise<VisionModel> {
  if (env().LLM_PROVIDER !== 'fake') {
    try {
      const ai = await (await import('@/lib/platform/runtime')).aiBinding();
      if (ai) {
        const { workersAiVision } = await import('./workers-ai');
        // the toll notices and plates go through the usage guard too (0080, 0104)
        const [{ guardVision }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
        return guardVision(workersAiVision(ai), aiRoom.paused, aiRoom.spent);
      }
    } catch { /* not running in the Worker */ }
    const key = env().GEMINI_API_KEY?.trim();
    if (key) {
      const [{ geminiVision, GEMINI_DEFAULT_MODEL }, { guardVision }, { aiRoom }, { geminiRelay }] = await Promise.all([import('./gemini'), import('../ai/guard'), import('../ai/paused'), import('@/server/gemini-relay')]);
      const g = geminiVision(key, env().GEMINI_VISION_MODEL || GEMINI_DEFAULT_MODEL, 30_000, fetch, geminiRelay());
      // identity documents are never sent to Gemini's free tier (Google may use free-tier requests): typed by a person
      return guardVision({ name: g.name, read: (req, models) => PERSONAL.has(req.purpose) ? Promise.resolve({ ok: false, reason: 'unavailable', message: 'Identity documents are not read by Gemini', tried: [] }) : g.read(req, models) }, aiRoom.paused, aiRoom.spent);
    }
  }
  return fakeVision();
}
export type * from './types';
