import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { textGenerator } from '@/integrations/llm';
import { parseAiSignals } from '@/features/intent/model';

// Lead intent (migration 1506): the optional AI reading of what a renter or a lead said, on top of the rules. The database
// hands one subject at a time only while the setting is on and the background share of today's free Workers AI allowance
// has room (server_intent_ai_due; a hard stop), and keeps only the signals the rules left empty (server_intent_ai_result).
const SR = { role: 'service_role' as const };
const SCHEMA = { type: 'object', properties: {
  budget: { type: 'object', properties: { amount: { type: 'number' }, per: { type: 'string', enum: ['day', 'week', 'month', 'total'] } } },
  car_class: { type: 'string', enum: ['suv', 'minivan', 'pickup', 'electric', 'sports', 'luxury', 'economy', 'sedan'] }, duration_days: { type: 'integer' },
  dates: { type: 'string' }, urgency: { type: 'string', enum: ['high', 'medium'] }, delivery: { type: 'boolean' },
  coverage: { type: 'string', enum: ['card', 'own_insurance', 'protection_plan', 'insurer_claim'] } } };
const SYSTEM = 'You read what a customer of CarmaCars, a car rental company in Toronto, said in calls, texts, emails and chat. Answer in JSON with only what the customer clearly said: budget {amount in dollars, per day|week|month|total}, car_class, duration_days, dates (as they said them), urgency (high: today or now; medium: within days), delivery (true if they want the car brought to them), coverage (card, own_insurance, protection_plan, insurer_claim). Leave out anything not said. Never guess.';

export async function runIntentAi(): Promise<{ read: number; skipped?: string }> {
  const due = (await rpc('server_intent_ai_due', { p_limit: 1 }, SR).catch(() => null)) as unknown as { ok: boolean; why?: string; items: Array<{ kind: string; id: string; sha: string; text: string }> } | null;
  if (!due?.ok || !due.items.length) return { read: 0, skipped: due?.why ?? 'nothing due' };
  let read = 0;
  for (const it of due.items) {
    const t0 = Date.now();
    const gen = await textGenerator(undefined, 20_000);
    const r = await gen.generate<Record<string, unknown>>({ task: 'intent_read', maxOutputTokens: 120, temperature: 0, schema: SCHEMA, system: SYSTEM, prompt: `<messages>\n${it.text}\n</messages>` });
    await rpc('server_intent_ai_result', { p: { kind: it.kind, id: it.id, sha: it.sha, signals: r.ok ? parseAiSignals(r.data) : null, error: r.ok ? null : r.message,
      neurons: r.usage?.neurons ?? 0, model: gen.model ?? null, duration_ms: Date.now() - t0 } as unknown as Json }, SR);
    if (!r.ok) break;
    read++;
  }
  return { read };
}
