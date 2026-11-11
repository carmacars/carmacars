import 'server-only';
import { env } from '@/lib/env';
import type { Transcriber } from './types';
import { fakeTranscriber } from './fake';

// LLM_PROVIDER=workers-ai uses the Worker's AI binding (production); without the binding (a local server) or with
// LLM_PROVIDER=fake the fake answers. Every call goes through the usage guard (0133): the interviews' transcripts are
// live work and must fit that share of the day's free allowance (a hard stop, no paid usage).
/** purpose: the usage guard's feature (interview_transcribe is live; 1880's call_transcribe is background). */
export async function transcriber(purpose = 'interview_transcribe'): Promise<Transcriber> {
  if (env().LLM_PROVIDER === 'workers-ai') {
    try {
      const { getCloudflareContext } = await import('@opennextjs/cloudflare');
      const { env: cf } = await getCloudflareContext({ async: true });
      const ai = (cf as unknown as { AI?: import('./workers-ai').AiBinding }).AI;
      if (ai) {
        const { workersAiTranscriber } = await import('./workers-ai');
        const [{ guardTranscriber }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
        return guardTranscriber(workersAiTranscriber(ai), aiRoom.paused, aiRoom.spent, purpose);
      }
    } catch { /* not running in the Worker */ }
  }
  return fakeTranscriber();
}
export type * from './types';
