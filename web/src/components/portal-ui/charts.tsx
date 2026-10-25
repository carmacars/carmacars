import type { ReactNode } from 'react';

// Lightweight charts for the portals: plain HTML bars and inline SVG lines, no chart library. Each chart carries its
// numbers as text too (a visually hidden paragraph, or the column buttons' names), so it reads without the picture. Movement is CSS only,
// under prefers-reduced-motion: no-preference (portal-ui.css).

export interface Bar { key: string; label: string; short: string; value: number; display: string; accent?: boolean }

/**
 * Columns for a few months. With `onSelect` (a client parent) each column is a button that selects its month
 * (aria-pressed); without it the chart is static. The values are shown on hover, focus and for the selected column.
 */
export function BarChart({ bars, title, selected, onSelect, testId, caption }: { bars: Bar[]; title: string; selected?: string; onSelect?: (key: string) => void; testId?: string; caption?: ReactNode }) {
  const max = Math.max(1, ...bars.map((b) => b.value));
  return (
    <figure className="pu-chart" data-testid={testId}>
      <div className="pu-bars" aria-hidden={onSelect ? undefined : true} role={onSelect ? 'group' : undefined} aria-label={onSelect ? title : undefined}>
        {bars.map((b, i) => {
          const h = `${Math.max(2, (b.value / max) * 100)}%`;
          const inner = <><span className="pu-bar__fill" style={{ height: h, ['--i' as string]: i }} /><span className="pu-bar__val" style={{ bottom: `calc(${h} + 0.35rem)` }}>{b.display}</span></>;
          const cls = `pu-bar${b.accent ? ' is-accent' : ''}${!onSelect && selected === b.key ? ' is-on' : ''}`;
          return onSelect
            ? <button key={b.key} type="button" className={cls} aria-pressed={selected === b.key} aria-label={`${b.label}: ${b.display}`} onClick={() => onSelect(b.key)} data-key={b.key}>{inner}</button>
            : <span key={b.key} className={cls}>{inner}</span>;
        })}
      </div>
      <div className="pu-bars__labels" aria-hidden="true">{bars.map((b) => <span key={b.key} className={selected === b.key ? 'is-on' : undefined}>{b.short}</span>)}</div>
      {!onSelect && <p className="vh">{`${title}: ${bars.map((b) => `${b.label}, ${b.display}`).join('; ')}.`}</p>}
      {caption && <figcaption className="pu-chart__cap">{caption}</figcaption>}
    </figure>
  );
}

/** A small trend line (decorative: the figure beside it says the same in words). */
export function Sparkline({ values, className = '' }: { values: number[]; className?: string }) {
  if (values.length < 2) return null;
  const w = 120, h = 40, max = Math.max(...values), min = Math.min(...values, 0);
  const span = max - min || 1;
  const pts = values.map((v, i) => [(i / (values.length - 1)) * w, h - 3 - ((v - min) / span) * (h - 6)] as const);
  const line = pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
  return (
    <svg className={`pu-spark ${className}`} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true" focusable="false">
      <path className="pu-spark__area" d={`${line} L${w} ${h} L0 ${h} Z`} />
      <path className="pu-spark__line" d={line} />
    </svg>
  );
}

export interface Series { key: string; label: string; values: Array<number | null>; tone?: 'ink' | 'accent' | 'dash'; fill?: boolean }

/**
 * Lines over months (for example the Invested Amount and the Returns to date), with month ticks, a value axis and the
 * numbers in a visually hidden table. Values in cents; `fmt` formats a tick.
 */
export function LineChart({ labels, series, title, fmt, testId, height = 240 }: { labels: string[]; series: Series[]; title: string; fmt: (v: number) => string; testId?: string; height?: number }) {
  const W = 420, H = height, L = 52, R = 10, T = 12, B = 26;
  const all = series.flatMap((s) => s.values.filter((v): v is number => v !== null));
  const max = Math.max(1, ...all);
  const nice = niceMax(max);
  const x = (i: number) => L + (labels.length < 2 ? 0 : (i / (labels.length - 1)) * (W - L - R));
  const y = (v: number) => T + (1 - v / nice) * (H - T - B);
  const path = (vals: Array<number | null>) => {
    let d = ''; let pen = false;
    vals.forEach((v, i) => { if (v === null) { pen = false; return; } d += `${pen ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)} `; pen = true; });
    return d.trim();
  };
  const every = Math.max(1, Math.ceil(labels.length / 6));
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((p) => p * nice);
  return (
    <figure className="pu-chart" data-testid={testId}>
      <div className="pu-chart__plot">
        <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title} focusable="false">
          <defs><linearGradient id="pu-grad" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#D0111B" stopOpacity="0.22" /><stop offset="1" stopColor="#D0111B" stopOpacity="0" /></linearGradient></defs>
          {ticks.map((t) => <g key={t}><line className="pu-area__grid" x1={L} x2={W - R} y1={y(t)} y2={y(t)} /><text className="pu-area__tick" x={L - 8} y={y(t) + 4} textAnchor="end">{compact(t)}</text></g>)}
          {labels.map((l, i) => ((i % every === 0 && labels.length - 1 - i >= every) || i === labels.length - 1) ? <text key={i} className="pu-area__tick" x={x(i)} y={H - 8} textAnchor={i === 0 ? 'start' : i === labels.length - 1 ? 'end' : 'middle'}>{l}</text> : null)}
          {series.filter((s) => s.fill).map((s) => {
            const d = path(s.values); const first = s.values.findIndex((v) => v !== null); const last = s.values.length - 1 - [...s.values].reverse().findIndex((v) => v !== null);
            return d ? <path key={`f${s.key}`} className="pu-area__fill" d={`${d} L${x(last)} ${y(0)} L${x(first)} ${y(0)} Z`} /> : null;
          })}
          {series.map((s) => <path key={s.key} className={`pu-area__line${s.tone === 'accent' ? ' pu-area__line--accent' : s.tone === 'dash' ? ' pu-area__line--dash' : ''}`} d={path(s.values)} style={{ ['--len' as string]: 1600 }} />)}
          {series.filter((s) => s.tone !== 'dash').map((s) => { const i = s.values.length - 1 - [...s.values].reverse().findIndex((v) => v !== null); const v = s.values[i]; return v === null || v === undefined || i >= s.values.length ? null : <circle key={`d${s.key}`} className="pu-area__dot" cx={x(i)} cy={y(v)} r="4" />; })}
        </svg>
      </div>
      <ul className="pu-legend" aria-hidden="true">{series.map((s) => <li key={s.key}><i className={s.tone === 'accent' ? 'is-accent' : s.tone === 'dash' ? 'is-dash' : undefined} />{s.label}</li>)}</ul>
      <p className="vh">{`${title}: ${labels.map((l, i) => `${l}: ${series.filter((x) => x.values[i] !== null && x.values[i] !== undefined).map((x) => `${x.label} ${fmt(x.values[i] as number)}`).join(', ') || 'no figure'}`).join('; ')}.`}</p>
    </figure>
  );
}

/** A value axis tick in cents, short: $50k, $2.5k, $800. */
function compact(cents: number): string {
  const d = cents / 100;
  if (d >= 1000) { const k = d / 1000; return `$${Number.isInteger(k) ? k : k.toFixed(1)}k`; }
  return `$${Math.round(d)}`;
}

function niceMax(v: number): number {
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10) * p;
}
