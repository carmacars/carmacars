import 'server-only';
import { env } from '@/lib/env';
import type { TextGenerator } from './types';
import { fakeText } from './fake';

// LLM_PROVIDER=workers-ai uses the Worker's AI binding (production); without the binding (a local
// server, next start) or with LLM_PROVIDER=fake the fake writes a plain draft from the facts.
export async function textGenerator(model?: string, timeoutMs?: number): Promise<TextGenerator> {
  if (env().LLM_PROVIDER === 'workers-ai') {
    try {
      const { getCloudflareContext } = await import('@opennextjs/cloudflare');
      const { env: cf } = await getCloudflareContext({ async: true });
      const ai = (cf as unknown as { AI?: import('./workers-ai').AiBinding }).AI;
      if (ai) {
        const { workersAi } = await import('./workers-ai');
        return workersAi(ai, model, timeoutMs);
      }
    } catch { /* not running in the Worker */ }
  }
  return fakeText();
}
export type * from './types';
