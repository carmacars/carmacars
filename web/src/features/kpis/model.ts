// Role KPIs (migration 1504): the words of one KPI against its target (a Program setting).
//   node --test --experimental-strip-types src/features/kpis/model.test.ts   (npm run test:unit)
export interface Kpi { key: string; label: string; value: number | null; target: number | null; unit: 'count' | 'pct' | 'days' | 'min'; met: boolean | null; detail: string | null }

export function kpiValue(k: Kpi): string {
  if (k.value === null || k.value === undefined) return 'no cases';
  return k.unit === 'pct' ? `${k.value}%` : k.unit === 'days' ? `${k.value} day${k.value === 1 ? '' : 's'}` : String(k.value);
}
export function kpiTarget(k: Kpi): string {
  if (!k.target) return 'no target';
  return k.unit === 'pct' ? `${k.target}% or more` : k.unit === 'days' ? `${k.target} day${k.target === 1 ? '' : 's'}` : `${k.target} a week`;
}
/** 'met', 'missed' or 'none' (no cases yet, or no target) */
export const kpiState = (k: Kpi): 'met' | 'missed' | 'none' => (k.met === true ? 'met' : k.met === false ? 'missed' : 'none');
