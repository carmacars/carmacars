import './history.css';
import { chartModel, type DayFigure } from './history';

// Visitor history (migration 0118): visits per day as bars with the conversions inside them, unique visitors as a
// line, like the usage chart (Settings > Usage); the figures as a table for screen readers and anyone who wants them.
export function VisitChart({ days, at }: { days: DayFigure[]; at: string | null }) {
  if (!days.some((d) => d.visits > 0)) return <p className="small muted" data-testid="vh-chart-empty">No visits in these dates yet. The totals are worked out every 15 minutes.</p>;
  const m = chartModel(days);
  const fmt = (n: number) => n.toLocaleString('en-US');
  return (
    <figure className="vh-chart" data-testid="vh-chart">
      <svg viewBox={`0 0 ${m.W} ${m.H}`} role="img" preserveAspectRatio="none"
        aria-label={`Visits per day from ${days[0]!.day} to ${days[days.length - 1]!.day}: busiest ${m.peak!.day} with ${fmt(m.peak!.visits)} visits`}>
        {m.bars.map((b) => <g key={b.day}><rect className="vh-chart__visits" x={b.x} y={b.y} width={b.w} height={b.h} />{b.ch > 0 && <rect className="vh-chart__conv" x={b.x} y={b.cy} width={b.w} height={b.ch} />}</g>)}
        {days.length > 1 && <polyline className="vh-chart__line" points={m.line} />}
      </svg>
      <figcaption className="small muted vh-legend">
        <span><i className="vh-key vh-key--visits" aria-hidden="true" />Visits</span>
        <span><i className="vh-key vh-key--conv" aria-hidden="true" />Converted</span>
        <span><i className="vh-key vh-key--line" aria-hidden="true" />Unique visitors</span>
        {at && <span>Worked out {new Date(at).toLocaleString('en-CA', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' })}</span>}
      </figcaption>
      <details className="todo__clear"><summary className="small muted">The figures</summary>
        <table className="ad-table small" data-testid="vh-chart-table"><thead><tr><th scope="col">Day</th><th scope="col" className="num">Visits</th><th scope="col" className="num">Unique visitors</th><th scope="col" className="num">Converted</th><th scope="col" className="num">Pages</th></tr></thead>
          <tbody>{days.filter((d) => d.visits > 0).reverse().map((d) => <tr key={d.day}><td>{d.day}</td><td className="num">{fmt(d.visits)}</td><td className="num">{fmt(d.visitors)}</td><td className="num">{fmt(d.converted)}</td><td className="num">{fmt(d.page_views)}</td></tr>)}</tbody></table></details>
    </figure>
  );
}
