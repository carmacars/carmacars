import 'server-only';
import { env } from '@/lib/env';
import type { Transcriber } from './types';
import { fakeTranscriber } from './fake';

// LLM_PROVIDER=workers-ai uses the Worker's AI binding (production) or Workers AI's REST API; without either the call
// answers "unavailable" (never the fake's invented words on the live site). LLM_PROVIDER=fake: the fake (local, tests).
// Every call goes through the usage guard (0133): the interviews' transcripts are live work and must fit that share of the day's free allowance (a hard stop, no paid usage).
/** purpose: the usage guard's feature (interview_transcribe is live; 1880's call_transcribe is background). */
export async function transcriber(purpose = 'interview_transcribe'): Promise<Transcriber> {
  if (env().LLM_PROVIDER !== 'fake') {
    try {
      const ai = await (await import('@/lib/platform/runtime')).aiBinding();
      if (ai) {
        const { workersAiTranscriber } = await import('./workers-ai');
        const [{ guardTranscriber }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
        return guardTranscriber(workersAiTranscriber(ai), aiRoom.paused, aiRoom.spent, purpose);
      }
    } catch { /* not running in the Worker */ }
    // r48 (3070): no Workers AI here (the company's server without its token). Recordings are never sent to Gemini's free
    // tier (Google may use free-tier requests; calls and interviews are personal): the transcript waits, a person listens
    return unavailableTranscriber();
  }
  return fakeTranscriber();
}
export type * from './types';

/** A transcriber that is not there: every call answers unavailable (the reviewer listens to the recording). */
export function unavailableTranscriber(): Transcriber {
  return { name: 'fake', async transcribe() { return { ok: false, reason: 'unavailable', message: 'Speech to text is not connected on this server (no Workers AI token)' }; } };
}
