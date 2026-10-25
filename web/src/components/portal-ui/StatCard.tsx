import type { ReactNode } from 'react';
import { AnimatedNumber, type NumberFormat } from './AnimatedNumber';

const ARROW = { up: <path d="M8 13V3M3.5 7.5 8 3l4.5 4.5" fill="none" stroke="currentColor" strokeWidth="2" />, down: <path d="M8 3v10M3.5 8.5 8 13l4.5-4.5" fill="none" stroke="currentColor" strokeWidth="2" /> };

/** A change against an earlier figure, in words as well as an arrow (colour is never the only signal). */
export function Delta({ now, before, label = 'vs last month' }: { now: number; before: number; label?: string }) {
  if (!before && !now) return null;
  const dir = now > before ? 'up' : now < before ? 'down' : 'flat';
  const pctv = before ? Math.round(((now - before) / Math.abs(before)) * 100) : null;
  const words = dir === 'flat' ? `Same as ${label.replace(/^vs /, '')}` : pctv === null ? `New ${label}` : `${dir === 'up' ? 'Up' : 'Down'} ${Math.abs(pctv)}% ${label}`;
  return (
    <span className="pu-stat__delta" data-dir={dir}>
      {dir !== 'flat' && <svg viewBox="0 0 16 16" aria-hidden="true">{ARROW[dir]}</svg>}
      {words}
    </span>
  );
}

/**
 * One figure with its label. `value` animates when it is a number (money in cents with format "money" or "cents");
 * pass a node for anything else (a date, a word).
 */
export function StatCard({ label, value, format = 'int', sub, delta, testId, card = false, size, className = '' }: {
  label: ReactNode; value: number | ReactNode; format?: NumberFormat; sub?: ReactNode; delta?: ReactNode; testId?: string; card?: boolean; size?: 'lg'; className?: string;
}) {
  return (
    <div className={`pu-stat${card ? ' pu-stat--card' : ''}${size === 'lg' ? ' pu-stat--lg' : ''} ${className}`.trim()}>
      <span className="pu-stat__label">{label}</span>
      <b className="pu-stat__value">{typeof value === 'number' ? <AnimatedNumber value={value} format={format} testId={testId} /> : <span data-testid={testId}>{value}</span>}</b>
      {delta}
      {sub && <span className="pu-stat__sub">{sub}</span>}
    </div>
  );
}
