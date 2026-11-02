import type { ModelMonth } from './engine';

// EBITDA by month (bars: actual months solid black, forecast grey, losses red) and closing cash (the red line, its own
// scale on the right). Inline SVG, no library; the same figures are in the table below it and in a hidden summary.
const compact = (v: number) => { const a = Math.abs(v); const s = a >= 1e6 ? `${+(a / 1e6).toFixed(1)}M` : a >= 1e3 ? `${Math.round(a / 1e3)}k` : `${Math.round(a)}`; return `${v < 0 ? '-' : ''}$${s}`; };
function nice(v: number) { if (v <= 0) return 1; const p = 10 ** Math.floor(Math.log10(v)); const m = v / p; return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p; }

export function ModelChart({ months, title }: { months: ModelMonth[]; title: string }) {
  const W = 960, H = 280, L = 56, R = 60, T = 14, B = 30;
  const e = months.map((m) => m.ebitda), cash = months.map((m) => m.closingCash);
  const eMax = nice(Math.max(1, ...e.map(Math.abs)));
  const eMin = Math.min(0, ...e) < 0 ? -nice(Math.abs(Math.min(...e))) : 0;
  const cMax = nice(Math.max(1, ...cash.map(Math.abs)));
  const cMin = Math.min(0, ...cash) < 0 ? -nice(Math.abs(Math.min(...cash))) : 0;
  const bw = (W - L - R) / months.length;
  const y = (v: number) => T + (1 - (v - eMin) / (eMax - eMin)) * (H - T - B);
  const yc = (v: number) => T + (1 - (v - cMin) / (cMax - cMin)) * (H - T - B);
  const line = cash.map((v, i) => `${i ? 'L' : 'M'}${(L + bw * (i + 0.5)).toFixed(1)} ${yc(v).toFixed(1)}`).join(' ');
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((p) => eMin + p * (eMax - eMin));
  const every = Math.ceil(months.length / 12);
  const low = months.reduce((lo, m) => (m.closingCash < lo.closingCash ? m : lo), months[0]!);
  return (
    <figure className="pu-chart" data-testid="model-chart">
      <svg className="im-chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title}>
        {ticks.map((t) => <g key={t}><line className="g" x1={L} x2={W - R} y1={y(t)} y2={y(t)} /><text className="t" x={L - 8} y={y(t) + 4} textAnchor="end">{compact(t)}</text></g>)}
        {[0, 0.5, 1].map((p) => { const v = cMin + p * (cMax - cMin); return <text key={p} className="t" x={W - R + 8} y={yc(v) + 4}>{compact(v)}</text>; })}
        <line className="z" x1={L} x2={W - R} y1={y(0)} y2={y(0)} />
        {months.map((m, i) => {
          const top = Math.min(y(0), y(m.ebitda)), h = Math.max(1, Math.abs(y(m.ebitda) - y(0)));
          const cls = m.ebitda < 0 ? (m.kind === 'A' ? 'neg-a' : 'neg-f') : m.kind === 'A' ? 'bar-a' : 'bar-f';
          return <rect key={m.month} className={cls} x={L + bw * i + bw * 0.15} width={bw * 0.7} y={top} height={h} rx={2} />;
        })}
        <path className="cash" d={line} />
        {months.map((m, i) => (i % every === 0 ? <text key={m.month} className="t" x={L + bw * (i + 0.5)} y={H - 10} textAnchor="middle">{new Date(`${m.month}T12:00:00Z`).toLocaleDateString('en-CA', { month: 'short', year: '2-digit', timeZone: 'UTC' })}</text> : null))}
      </svg>
      <ul className="im-legend" aria-hidden="true">
        <li><i style={{ background: '#111' }} />EBITDA, actual</li><li><i style={{ background: '#C7C7CC' }} />EBITDA, forecast</li><li><i style={{ background: '#B00E16' }} />A loss</li><li><i style={{ background: '#D0111B', height: 3 }} />Closing cash (right scale)</li>
      </ul>
      <p className="vh">{`${title}. EBITDA from ${compact(Math.min(...e))} to ${compact(Math.max(...e))} a month; closing cash lowest ${compact(low.closingCash)} in ${low.month.slice(0, 7)}, ${compact(cash[cash.length - 1] ?? 0)} at the end.`}</p>
    </figure>
  );
}
