import { Card, d } from '@/features/admin/ui';

// The weekly scorecard (VA hiring package section 7; 05-va.md section 6): each measure is the share of its
// cases that met the target that week. Under 90% two weeks running means a review.
export interface Score { name: string; function: string | null; review: boolean;
  weeks: Array<{ week_start: string; score_pct: number | null; measures: Array<{ name: string; target: string; met: number; total: number; score_pct: number | null }> }> }

const pct = (v: number | null) => (v === null || v === undefined ? 'no cases' : `${v}%`);

export function Scorecard({ s }: { s: Score }) {
  const weeks = [...s.weeks].reverse();
  const names = weeks[0]?.measures.map((m) => [m.name, m.target] as const) ?? [];
  return (
    <>
      {s.review && <p className="alert alert--warn" role="status" data-testid="score-review"><span className="alert__title">Review</span><span>Two weeks running under 90%.</span></p>}
      <Card title="By week" testId="scorecard">
        <div className="ad-scroll" tabIndex={0} role="region" aria-label="Scorecard by week">
          <table className="ad-table ad-table--dense">
            <thead><tr><th scope="col">Measure</th><th scope="col" className="wrap">Target</th>{weeks.map((w) => <th key={w.week_start} scope="col" className="num">Week of {d(w.week_start)}</th>)}</tr></thead>
            <tbody>
              {names.map(([n, target]) => (
                <tr key={n}><th scope="row" className="wrap">{n}</th><td className="wrap">{target}</td>
                  {weeks.map((w) => { const m = w.measures.find((x) => x.name === n); return (
                    <td key={w.week_start} className={`num ad-score${m && m.score_pct !== null && m.score_pct < 90 ? ' ad-score--low' : ''}`}>{m && m.total ? `${pct(m.score_pct)} (${m.met} of ${m.total})` : 'no cases'}</td>); })}</tr>
              ))}
              <tr><th scope="row">Week</th><td />{weeks.map((w) => <td key={w.week_start} className={`num ad-score${w.score_pct !== null && w.score_pct < 90 ? ' ad-score--low' : ''}`}><b>{pct(w.score_pct)}</b></td>)}</tr>
            </tbody>
          </table>
        </div>
        <p className="small muted">A task met its target when it was done by its due time; one still open after its due time missed it. Daily checks count when done by 9:00 and 18:00.</p>
      </Card>
    </>
  );
}
