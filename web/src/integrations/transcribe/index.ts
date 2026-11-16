import 'server-only';
import { env } from '@/lib/env';
import type { Transcriber } from './types';
import type { Provider } from '../ai/chain';
import { fakeTranscriber } from './fake';

// Speech to text through the chain (r48 part AI, 3095; src/integrations/ai/chain.ts): Workers AI Whisper (the Worker's AI
// binding or its REST API; behind the usage guard: the interviews' transcripts are live work and must fit that share of
// the day's free allowance, a hard stop, no paid usage), then the server's own whisper.cpp (carmacars-stt). Recordings
// are never sent to Gemini. Without either the call answers "unavailable" (never the fake's invented words on the live
// site: a person listens). LLM_PROVIDER=fake: the fake (local, tests).
/** purpose: the usage guard's feature (interview_transcribe is live; 1880's call_transcribe is background). */
export async function transcriber(purpose = 'interview_transcribe'): Promise<Transcriber> {
  if (env().LLM_PROVIDER === 'fake') return fakeTranscriber();
  const links: Partial<Record<Provider, Transcriber>> = {};
  try {
    const ai = await (await import('@/lib/platform/runtime')).aiBinding();
    if (ai) {
      const { workersAiTranscriber } = await import('./workers-ai');
      const [{ guardTranscriber }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
      links.workers_ai = guardTranscriber(workersAiTranscriber(ai), aiRoom.paused, aiRoom.spent, purpose);
    }
  } catch { /* not running in the Worker */ }
  const { localNow, localConf, chainDeps } = await import('../ai/links');
  const c = localConf();
  if (c.sttUrl && (await localNow()).stt) {
    const { localTranscriber } = await import('./local');
    links.local = localTranscriber(c.sttUrl);
  }
  if (!links.workers_ai && !links.local) return unavailableTranscriber();
  const { chainTranscriber } = await import('../ai/chain');
  return chainTranscriber(links, chainDeps(), purpose);
}
export type * from './types';

/** A transcriber that is not there: every call answers unavailable (the reviewer listens to the recording). */
export function unavailableTranscriber(): Transcriber {
  return { name: 'fake', async transcribe() { return { ok: false, reason: 'unavailable', message: 'Speech to text is not connected on this server (no Workers AI, and the local speech model is not ready yet)' }; } };
}
