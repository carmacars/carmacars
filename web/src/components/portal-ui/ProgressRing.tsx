import type { ReactNode } from 'react';

/** A ring that fills to value/max, with its figure in the middle and the same in words for screen readers. */
export function ProgressRing({ value, max, size = 72, stroke = 7, label, sub, title, accent = false, testId }: {
  value: number; max: number; size?: number; stroke?: number; label?: ReactNode; sub?: ReactNode; title: string; accent?: boolean; testId?: string;
}) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const p = max > 0 ? Math.max(0, Math.min(1, value / max)) : 0;
  return (
    <span className={`pu-ring${accent ? ' pu-ring--accent' : ''}`} role="img" aria-label={title} data-testid={testId} style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
        <circle className="pu-ring__track" cx={size / 2} cy={size / 2} r={r} fill="none" strokeWidth={stroke} />
        <circle className="pu-ring__bar" cx={size / 2} cy={size / 2} r={r} fill="none" strokeWidth={stroke} strokeDasharray={c} strokeDashoffset={c * (1 - p)} />
      </svg>
      {(label || sub) && <span className="pu-ring__label" aria-hidden="true"><span>{label}{sub && <small>{sub}</small>}</span></span>}
    </span>
  );
}
