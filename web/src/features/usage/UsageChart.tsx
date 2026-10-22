import './usage.css';
import { share } from './model';

// The last 30 days of one service (Settings > Usage, migration 0080): one bar per day, the allowance as a line for a
// daily service, and the figures as a table for screen readers and anyone who wants the numbers.
export function UsageChart({ s, history }: { s: { service: string; label: string; unit: string; period: string; included: number; used_text: string }; history: Array<{ day: string; used: number }> }) {
  if (!history.length) return <p className="small muted">No daily figures yet.</p>;
  const days: Array<{ day: string; used: number }> = [];
  const today = history[history.length - 1]!.day;
  for (let i = 29; i >= 0; i--) {
    const x = new Date(`${today}T12:00:00Z`); x.setUTCDate(x.getUTCDate() - i);
    const k = x.toISOString().slice(0, 10);
    days.push({ day: k, used: history.find((h) => h.day === k)?.used ?? 0 });
  }
  const line = s.period === 'day' ? s.included : 0;
  const max = Math.max(line, ...days.map((x) => x.used), 1);
  const W = 300, H = 60, bw = W / 30;
  const fmt = (n: number) => (s.unit === 'bytes' ? `${Math.round(n / 1048576).toLocaleString('en-US')} MB` : s.unit === 'microusd' ? `US$${(n / 1e6).toFixed(2)}` : Math.round(n).toLocaleString('en-US'));
  const peak = days.reduce((a, b) => (b.used > a.used ? b : a), days[0]!);
  return (
    <figure className="ug-chart" data-testid={`usage-chart-${s.service}`}>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${s.label}, last 30 days: highest ${fmt(peak.used)} on ${peak.day}${line ? `; the daily allowance is ${fmt(line)} (${share(Math.round(peak.used * 10000 / line))} on that day)` : ''}`} preserveAspectRatio="none">
        {days.map((x, i) => { const h = Math.max(x.used > 0 ? 1 : 0, (x.used / max) * (H - 2)); return <rect key={x.day} x={i * bw + 1} y={H - h} width={bw - 2} height={h} className={line && x.used >= line ? 'is-over' : ''} />; })}
        {line > 0 && <line x1={0} x2={W} y1={H - (line / max) * (H - 2)} y2={H - (line / max) * (H - 2)} className="ug-chart__line" />}
      </svg>
      <figcaption className="small muted">Last 30 days{line ? ', the line is the daily allowance' : ''}.</figcaption>
      <details className="todo__clear"><summary className="small muted">The figures</summary>
        <table className="ad-table small"><thead><tr><th scope="col">Day</th><th scope="col" className="num">Used</th></tr></thead>
          <tbody>{days.filter((x) => x.used > 0).reverse().map((x) => <tr key={x.day}><td>{x.day}</td><td className="num">{fmt(x.used)}</td></tr>)}</tbody></table></details>
    </figure>
  );
}
