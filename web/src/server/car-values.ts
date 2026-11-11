import 'server-only';
import { rpc } from '@/lib/db/repo';
import { textGenerator } from '@/integrations/llm';
import { readValue, VALUE_SCHEMA, VALUE_SYSTEM, valuePrompt, type CarFacts, type ValueAnswer } from '@/features/car-value/estimate';

// The value job (migration 1202), from the Worker's cron tick when public.server_jobs_due says "car_values": a few cars a
// tick with no Canadian Black Book value get an AI estimate from typical listing prices (Workers AI through the usage
// guard, so within the free daily allowance), kept with its source and date. A failed try waits a day; staff ask again
// with Refresh on the car page. The estimate decides only whether the Protection Plan may be offered (the $50,000 cap).
const SR = { role: 'service_role' as const };

export async function runCarValues(limit = 3): Promise<{ done: number; saved: number; failed: number }> {
  const due = ((await rpc('server_car_values_due' as never, { p_limit: limit } as never, SR)) ?? []) as unknown as Array<CarFacts & { vehicle_id: string }>;
  let saved = 0, failed = 0;
  if (!due.length) return { done: 0, saved, failed };
  const gen = await textGenerator(undefined, 15_000);
  for (const c of due) {
    const r = await gen.generate<ValueAnswer>({ task: 'value_estimate', system: VALUE_SYSTEM, prompt: valuePrompt(c), schema: VALUE_SCHEMA as unknown as Record<string, unknown>, maxOutputTokens: 120, temperature: 0.1 });
    const v = r.ok ? readValue(r.data) : null;
    await rpc('server_car_value_save' as never, { p_vehicle: c.vehicle_id, p_cents: v?.cents ?? null, p_source: r.ok ? `ai: ${r.model}` : 'ai', p_basis: v?.basis ?? null } as never, SR).catch(() => undefined);
    if (v) saved++; else failed++;
    // a quota answer stops the run: the allowance is spent for today
    if (!r.ok && r.reason === 'quota') break;
  }
  return { done: due.length, saved, failed };
}
