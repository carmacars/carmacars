import type { ReactNode } from 'react';

/** Money rows with an optional total row. Amounts are formatted by the caller, exactly as the database gave them. */
export function MoneySummary({ rows, total, label }: { rows: Array<{ label: ReactNode; value: ReactNode; testId?: string }>; total?: { label: ReactNode; value: ReactNode; testId?: string }; label?: string }) {
  return (
    <dl className="pu-money" aria-label={label}>
      {rows.map((r, i) => <div key={i}><dt>{r.label}</dt><dd data-testid={r.testId}>{r.value}</dd></div>)}
      {total && <div className="pu-money__total"><dt>{total.label}</dt><dd data-testid={total.testId}>{total.value}</dd></div>}
    </dl>
  );
}
