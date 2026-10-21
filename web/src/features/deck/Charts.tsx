// Small SVG charts for the deck: no library, readable in print, red, black and grey only.
const fmtK = (cents: number) => {
  const d = cents / 100;
  return d >= 1_000_000 ? `$${(d / 1_000_000).toFixed(d >= 10_000_000 ? 0 : 1)}M` : d >= 1000 ? `$${Math.round(d / 1000)}k` : `$${Math.round(d)}`;
};
function niceMax(v: number): number {
  if (v <= 0) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
}

export interface Series { name: string; color: string; dash?: boolean; values: number[] }

/** A line chart over months: x from 0 to n, y in cents from a floor (the amount invested) up. */
export function LineChart({ series, labels, title, lockupMonths, floor = 0, height = 260 }: {
  series: Series[]; labels: string[]; title: string; lockupMonths?: number; floor?: number; height?: number;
}) {
  const W = 760, H = height, L = 58, R = 16, T = 14, B = 34;
  const n = Math.max(1, labels.length - 1);
  const top = niceMax(Math.max(...series.flatMap((s) => s.values)) - floor) + floor;
  const lo = floor;
  const x = (i: number) => L + ((W - L - R) * i) / n;
  const y = (v: number) => T + (H - T - B) * (1 - (v - lo) / Math.max(1, top - lo));
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => lo + (top - lo) * f);
  const every = Math.max(1, Math.ceil(labels.length / 10));
  return (
    <svg className="dk-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title}>
      <title>{title}</title>
      {lockupMonths ? <g><rect x={x(0)} y={T} width={x(Math.min(lockupMonths, n)) - x(0)} height={H - T - B} fill="#F0F0F0" />
        <text x={x(0) + 6} y={T + 14} fontSize="11" fill="#5E5E5E">Lockup: no return</text></g> : null}
      {ticks.map((t, k) => <g key={k}><line x1={L} x2={W - R} y1={y(t)} y2={y(t)} stroke="#E2E2E2" /><text x={L - 6} y={y(t) + 4} fontSize="11" textAnchor="end" fill="#5E5E5E">{fmtK(t)}</text></g>)}
      {labels.map((l, i) => (i % every === 0 || i === labels.length - 1) && <text key={i} x={x(i)} y={H - 12} fontSize="11" textAnchor="middle" fill="#5E5E5E">{l}</text>)}
      {series.map((s) => <polyline key={s.name} fill="none" stroke={s.color} strokeWidth="3" strokeDasharray={s.dash ? '7 5' : undefined} strokeLinejoin="round"
        points={s.values.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' ')} />)}
    </svg>
  );
}

/** Grouped bars: one group per label, one bar per series. */
export function BarChart({ groups, series, title, height = 240 }: { groups: string[]; series: Series[]; title: string; height?: number }) {
  const W = 760, H = height, L = 58, R = 10, T = 18, B = 30;
  const top = niceMax(Math.max(1, ...series.flatMap((s) => s.values)));
  const gw = (W - L - R) / groups.length;
  const bw = Math.min(46, (gw * 0.7) / series.length);
  const y = (v: number) => T + (H - T - B) * (1 - v / top);
  return (
    <svg className="dk-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title}>
      <title>{title}</title>
      {[0, 0.25, 0.5, 0.75, 1].map((f, k) => <g key={k}><line x1={L} x2={W - R} y1={y(top * f)} y2={y(top * f)} stroke="#E2E2E2" /><text x={L - 6} y={y(top * f) + 4} fontSize="11" textAnchor="end" fill="#5E5E5E">{fmtK(top * f)}</text></g>)}
      {groups.map((g, gi) => {
        const x0 = L + gi * gw + (gw - bw * series.length) / 2;
        return <g key={g}>
          {series.map((s, si) => <g key={s.name}><rect x={x0 + si * bw + 2} y={y(s.values[gi])} width={bw - 4} height={Math.max(0, y(0) - y(s.values[gi]))} fill={s.color} />
            <text x={x0 + si * bw + bw / 2} y={y(s.values[gi]) - 4} fontSize="10" textAnchor="middle" fill="#1A1A1A">{fmtK(s.values[gi])}</text></g>)}
          <text x={L + gi * gw + gw / 2} y={H - 10} fontSize="12" textAnchor="middle" fill="#1A1A1A">{g}</text>
        </g>;
      })}
    </svg>
  );
}
