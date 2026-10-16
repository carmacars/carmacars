import Link from 'next/link';

// What is signed and what is left, at the top of a signing page (migration 0049): "2 of 3 signed", then each document
// with its state and, for what is not signed here, where it is done.
export interface ProgressItem { key: string; label: string; done: boolean; note?: string | null; href?: string | null; here?: boolean }

export function SignProgress({ items, title = 'Your documents' }: { items: ProgressItem[]; title?: string }) {
  if (!items.length) return null;
  const done = items.filter((i) => i.done).length;
  return (
    <section className="pt-card stack sg-progress" aria-labelledby="sg-progress-h" data-testid="sign-progress">
      <div className="pt-card__head">
        <h2 className="d4" id="sg-progress-h">{title}</h2>
        <span className={`badge ${done === items.length ? 'badge--outline' : 'badge--red'}`} data-testid="sign-progress-count">{done} of {items.length} signed</span>
      </div>
      <div className="sg-progress__bar" role="progressbar" aria-label={`${done} of ${items.length} signed`} aria-valuemin={0} aria-valuemax={items.length} aria-valuenow={done}>
        <span style={{ width: `${Math.round((done / items.length) * 100)}%` }} />
      </div>
      <ul className="ck-items">
        {items.map((i) => (
          <li key={i.key} data-status={i.done ? 'done' : 'open'}>
            <span className={`ck-dot is-${i.done ? 'done' : 'open'}`} aria-hidden="true" />
            <span><b>{i.label}</b>{i.note ? `: ${i.note}` : ''}{!i.done && i.href && !i.here ? <> · <Link prefetch={false} className="link" href={i.href}>Open</Link></> : null}{!i.done && i.here ? ' · in this package' : ''}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

// The key values the documents were filled with, each with a Fix link to where it is kept: checked in seconds instead
// of reading every page (the full text stays one tap away).
export interface SummaryRow { label: string; value: string; fix?: string | null }
export function SignSummary({ rows, title = 'Check what we filled in' }: { rows: SummaryRow[]; title?: string }) {
  if (!rows.length) return null;
  return (
    <section className="pt-card stack" aria-labelledby="sg-summary-h" data-testid="sign-summary-values">
      <h2 className="d4" id="sg-summary-h">{title}</h2>
      <dl className="pt-dl sg-summary">
        {rows.map((r, n) => (
          <div key={`${r.label}-${n}`}><dt>{r.label}</dt><dd><span>{r.value || 'Not given yet'}</span>{r.fix ? <> <a className="link small" href={r.fix} data-testid="sign-fix">Fix</a></> : null}</dd></div>
        ))}
      </dl>
    </section>
  );
}
