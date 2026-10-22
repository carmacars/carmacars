import { AI_CAR_SYSTEM, acceptAiCar, aiCarPrompt, aiCarSchema, type MatchCar, type Scored, type Signals } from '@/features/turo/match';

// Turo by email (migration 0088): when the scored rules leave two or more cars, Workers AI picks one of that short list
// or answers "unsure". Its answer counts only when it is one of the short list (acceptAiCar). Within the day's neurons
// (turo_match_keys.ai_ok, the shared chat_ai_total_daily_neurons; the turo_email_ai switch); logged in provider_calls.
export async function aiPickCar(sig: Pick<Signals, 'carNames' | 'colours' | 'turoCarIds'>, subject: string, cars: MatchCar[], short: Scored[]):
  Promise<{ id: string | null; neurons: number }> {
  if (short.length < 2) return { id: null, neurons: 0 };
  const pool = cars.filter((c) => short.some((s) => s.vehicle_id === c.vehicle_id));
  if (pool.length < 2) return { id: null, neurons: 0 };
  const { textGenerator } = await import('@/integrations/llm');
  const gen = await textGenerator(undefined, 15_000);
  if (gen.name !== 'workers-ai') return { id: null, neurons: 0 };
  const a = await gen.generate<{ vehicle_id: string }>({ task: 'turo_email', system: AI_CAR_SYSTEM, prompt: aiCarPrompt(sig, subject, pool),
    schema: aiCarSchema(pool.map((c) => c.vehicle_id)), maxOutputTokens: 60, temperature: 0 });
  if (!a.ok) return { id: null, neurons: 0 };
  return { id: acceptAiCar(a.data, short), neurons: a.usage.neurons ?? 0 };
}

/** The best guesses as the database keeps them. */
export const guesses = (c: Scored[]) => c.slice(0, 6).map((x) => ({ vehicle_id: x.vehicle_id, score: x.score, why: x.why.slice(0, 8) }));
