// Lead intent (migration 1506): the words of a renter's or a lead's intent signals, for the lead, the renter and the live
// map. The AI's answer is checked here before the database checks it again.
//   node --test --experimental-strip-types src/features/intent/model.test.ts   (npm run test:unit)
export interface IntentSignals { budget?: { amount_cents: number; per: 'day' | 'week' | 'month' | 'total' }; car_class?: string; duration_days?: number; dates?: string;
  urgency?: 'high' | 'medium'; delivery?: boolean; coverage?: 'card' | 'own_insurance' | 'protection_plan' | 'insurer_claim' }
export interface Intent { score: number; label: 'hot' | 'warm' | 'cold' | 'unknown'; signals: IntentSignals; reasons?: Array<{ label: string; points: number }>; sources?: number; computed_at?: string; ai_at?: string | null }

const COVER: Record<string, string> = { card: 'credit card coverage', own_insurance: 'own insurance', protection_plan: 'Protection Plan', insurer_claim: 'insurance claim' };
const CLASS: Record<string, string> = { suv: 'SUV', minivan: 'minivan', pickup: 'pickup', electric: 'electric', sports: 'sports car', luxury: 'luxury', economy: 'economy', sedan: 'sedan' };

/** The signals as short phrases: "$600/week", "SUV", "14 days", "Nov 20", "needs it now", "delivery", "own insurance" */
export function intentPhrases(s: IntentSignals | null | undefined): string[] {
  if (!s) return [];
  const out: string[] = [];
  if (s.budget) out.push(`$${Math.round(s.budget.amount_cents / 100).toLocaleString('en-CA')}${s.budget.per === 'total' ? ' budget' : `/${s.budget.per}`}`);
  if (s.car_class) out.push(CLASS[s.car_class] ?? s.car_class);
  if (s.duration_days) out.push(s.duration_days % 30 === 0 ? `${s.duration_days / 30} month${s.duration_days === 30 ? '' : 's'}` : s.duration_days % 7 === 0 ? `${s.duration_days / 7} week${s.duration_days === 7 ? '' : 's'}` : `${s.duration_days} day${s.duration_days === 1 ? '' : 's'}`);
  if (s.dates) out.push(s.dates);
  if (s.urgency) out.push(s.urgency === 'high' ? 'needs it now' : 'needs it soon');
  if (s.delivery) out.push('delivery');
  if (s.coverage) out.push(COVER[s.coverage] ?? s.coverage);
  return out;
}
export function intentLine(i: Intent | null | undefined): string {
  if (!i || i.label === 'unknown') return 'No intent signals yet';
  const p = intentPhrases(i.signals);
  return `${i.label[0]!.toUpperCase()}${i.label.slice(1)} ${i.score}${p.length ? `: ${p.join(', ')}` : ''}`;
}

/** The AI's JSON reply as signals (only known keys and well-formed values; the database checks again). */
export function parseAiSignals(raw: unknown): IntentSignals | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const out: IntentSignals = {};
  const b = r.budget as Record<string, unknown> | null | undefined;
  if (b && typeof b === 'object' && Number.isFinite(Number(b.amount)) && Number(b.amount) >= 10 && Number(b.amount) <= 100000) {
    const per = String(b.per ?? 'total');
    out.budget = { amount_cents: Math.round(Number(b.amount) * 100), per: (['day', 'week', 'month'].includes(per) ? per : 'total') as 'day' | 'week' | 'month' | 'total' };
  }
  if (typeof r.car_class === 'string' && r.car_class.toLowerCase() in CLASS) out.car_class = r.car_class.toLowerCase();
  if (Number.isInteger(Number(r.duration_days)) && Number(r.duration_days) >= 1 && Number(r.duration_days) <= 365) out.duration_days = Number(r.duration_days);
  if (typeof r.dates === 'string' && r.dates.trim().length >= 3 && r.dates.length <= 60) out.dates = r.dates.trim();
  if (r.urgency === 'high' || r.urgency === 'medium') out.urgency = r.urgency;
  if (r.delivery === true) out.delivery = true;
  if (typeof r.coverage === 'string' && r.coverage in COVER) out.coverage = r.coverage as IntentSignals['coverage'];
  return out;
}
