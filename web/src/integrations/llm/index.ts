import 'server-only';
import { env } from '@/lib/env';
import type { TextGenerator } from './types';
import { fakeText } from './fake';

// LLM_PROVIDER=workers-ai uses the Worker's AI binding (production) or Workers AI's REST API on the company's server;
// r48 (3070): on the server without a Workers AI token, Gemini (GEMINI_API_KEY) answers instead. Without either (a local
// server, next start) or with LLM_PROVIDER=fake the fake writes a plain draft from the facts.
export async function textGenerator(model?: string, timeoutMs?: number): Promise<TextGenerator> {
  if (env().LLM_PROVIDER !== 'fake') {
    try {
      // the Worker's AI binding, or Workers AI's REST API on the company's server (src/lib/platform/runtime.ts)
      const ai = await (await import('@/lib/platform/runtime')).aiBinding();
      if (ai) {
        const { workersAi } = await import('./workers-ai');
        // every call goes through the usage guard (0080, 0104): nothing is asked while Workers AI is paused
        // 0133: by feature: each call must fit its tier's room of the day (the staff assistant's reserve is never used)
        const [{ guardText }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
        return guardText(workersAi(ai, model, timeoutMs), aiRoom.paused, aiRoom.spent);
      }
    } catch { /* not running in the Worker */ }
    const key = env().GEMINI_API_KEY?.trim();
    if (key) {
      const [{ geminiText, geminiModelFor }, { guardText }, { aiRoom }, { geminiRelay }] = await Promise.all([import('./gemini'), import('../ai/guard'), import('../ai/paused'), import('@/server/gemini-relay')]);
      return guardText(geminiText(key, geminiModelFor(model, env().GEMINI_TEXT_MODEL), timeoutMs || 60_000, fetch, geminiRelay()), aiRoom.paused, aiRoom.spent);
    }
  }
  return fakeText();
}
export type * from './types';
