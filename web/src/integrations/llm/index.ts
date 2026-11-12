import 'server-only';
import { env } from '@/lib/env';
import type { TextGenerator } from './types';
import { fakeText } from './fake';

// LLM_PROVIDER=workers-ai uses the Worker's AI binding (production); without the binding (a local
// server, next start) or with LLM_PROVIDER=fake the fake writes a plain draft from the facts.
export async function textGenerator(model?: string, timeoutMs?: number): Promise<TextGenerator> {
  if (env().LLM_PROVIDER === 'workers-ai') {
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
  }
  return fakeText();
}
export type * from './types';
