import 'server-only';
import { env } from '@/lib/env';
import type { VisionModel } from './types';
import { fakeVision } from './fake';

// LLM_PROVIDER=workers-ai (production) uses the Worker's AI binding; without the binding (a local server) or
// with LLM_PROVIDER=fake the fake answers.
export async function visionModel(): Promise<VisionModel> {
  if (env().LLM_PROVIDER === 'workers-ai') {
    try {
      const { getCloudflareContext } = await import('@opennextjs/cloudflare');
      const { env: cf } = await getCloudflareContext({ async: true });
      const ai = (cf as unknown as { AI?: import('./workers-ai').AiBinding }).AI;
      if (ai) {
        const { workersAiVision } = await import('./workers-ai');
        return workersAiVision(ai);
      }
    } catch { /* not running in the Worker */ }
  }
  return fakeVision();
}
export type * from './types';
