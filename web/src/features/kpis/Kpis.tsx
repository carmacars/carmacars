import { Card, d } from '@/features/admin/ui';
import { kpiState, kpiTarget, kpiValue, type Kpi } from './model';

// Role KPIs (migration 1504): one table of a person's KPIs, by week (the scorecard) or for one week (Admin > Team > KPIs,
// the field portal). The targets are Program settings (kpi_*).
export function KpiWeeks({ weeks, title = 'KPIs' }: { weeks: Array<{ week_start: string; items: Kpi[] }>; title?: string }) {
  const first = weeks[0];
  if (!first || !first.items.length) return null;
  return (
    <Card title={title} testId="kpis">
      <div className="ad-scroll" tabIndex={0} role="region" aria-label="KPIs by week">
        <table className="ad-table ad-table--dense">
          <thead><tr><th scope="col">KPI</th><th scope="col" className="wrap">Target</th>{weeks.map((w) => <th key={w.week_start} scope="col" className="num">Week of {d(w.week_start)}</th>)}</tr></thead>
          <tbody>{first.items.map((k) => (
            <tr key={k.key}><th scope="row" className="wrap">{k.label}</th><td className="wrap">{kpiTarget(k)}</td>
              {weeks.map((w) => { const x = w.items.find((y) => y.key === k.key); return (
                <td key={w.week_start} className={`num ad-score${x && kpiState(x) === 'missed' ? ' ad-score--low' : ''}`} data-testid={`kpi-${k.key}-${w.week_start}`} title={x?.detail ?? undefined}>
                  {x ? kpiValue(x) : ''}</td>); })}</tr>))}</tbody>
        </table>
      </div>
      <p className="small muted">This week counts up to now. A rate with no cases yet is neither met nor missed. Hover a figure for its detail.</p>
    </Card>
  );
}
