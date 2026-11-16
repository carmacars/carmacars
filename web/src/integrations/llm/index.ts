import 'server-only';
import { env } from '@/lib/env';
import type { TextGenerator } from './types';
import type { Provider } from '../ai/chain';
import { fakeText } from './fake';

// Every text task goes through the chain (r48 part AI, 3095; src/integrations/ai/chain.ts): Workers AI (the Worker's AI
// binding, or its REST API on the company's server; behind the usage guard), then the server's local model (Ollama,
// carmacars-llm), then Gemini (GEMINI_API_KEY) for what is not private. Each feature's order is its route in Admin >
// Settings > Usage, and every call records which provider served it. With no link at all (a local server, next start) or
// with LLM_PROVIDER=fake, the fake writes a plain draft from the facts.
export async function textGenerator(model?: string, timeoutMs?: number): Promise<TextGenerator> {
  if (env().LLM_PROVIDER === 'fake') return fakeText();
  const links: Partial<Record<Provider, TextGenerator>> = {};
  try {
    // the Worker's AI binding, or Workers AI's REST API on the company's server (src/lib/platform/runtime.ts)
    const ai = await (await import('@/lib/platform/runtime')).aiBinding();
    if (ai) {
      const { workersAi } = await import('./workers-ai');
      // every call goes through the usage guard (0080, 0104): nothing is asked while Workers AI is paused
      // 0133: by feature: each call must fit its tier's room of the day (the staff assistant's reserve is never used)
      const [{ guardText }, { aiRoom }] = await Promise.all([import('../ai/guard'), import('../ai/paused')]);
      links.workers_ai = guardText(workersAi(ai, model, timeoutMs), aiRoom.paused, aiRoom.spent);
    }
  } catch { /* not running in the Worker */ }
  const { localNow, localConf, chainDeps } = await import('../ai/links');
  const c = localConf();
  if (c.llmUrl && (await localNow()).text) {
    const { localText } = await import('./local');
    links.local = localText(c.llmUrl, c.textModel, timeoutMs);
  }
  const key = env().GEMINI_API_KEY?.trim();
  if (key) {
    const [{ geminiText, geminiModelFor }, { geminiRelay }] = await Promise.all([import('./gemini'), import('@/server/gemini-relay')]);
    // Gemini spends no neurons, so Workers AI's guard does not hold it (it is the fallback when that allowance is used);
    // its free tier's own limit answers 429, which is a quota answer
    links.gemini = geminiText(key, geminiModelFor(model, env().GEMINI_TEXT_MODEL), timeoutMs || 60_000, fetch, geminiRelay());
  }
  if (!links.workers_ai && !links.local && !links.gemini) return fakeText();
  const { chainText } = await import('../ai/chain');
  return chainText(links, chainDeps());
}
export type * from './types';
