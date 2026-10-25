'use client';
import { useId, useState } from 'react';

// A text to paste into another site (migration 0167): shown whole, selected on focus, with a Copy button and the count
// against the channel's limit.
export function CopyText({ label, value, rows = 1, max, testId }: { label: string; value: string; rows?: number; max?: number | null; testId?: string }) {
  const id = useId().replace(/:/g, '');
  const [copied, setCopied] = useState(false);
  const copy = () => { void navigator.clipboard?.writeText(value).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500); }); };
  const over = max ? value.length > max : false;
  return (
    <div className="field ad-field ad-field--wide">
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
        <label className="label" htmlFor={`${id}-v`}>{label}</label>
        <span className={`small ${over ? '' : 'muted'}`} aria-live="polite">{max ? `${value.length} of ${max} characters` : `${value.length} characters`}{over ? ': too long' : ''}</span>
      </div>
      {rows > 1
        ? <textarea id={`${id}-v`} className="input" readOnly rows={rows} value={value} onFocus={(e) => e.currentTarget.select()} data-testid={testId} />
        : <input id={`${id}-v`} className="input" readOnly value={value} onFocus={(e) => e.currentTarget.select()} data-testid={testId} />}
      <p className="row" style={{ marginTop: '0.4rem' }}><button className="btn btn--ghost btn--sm" type="button" onClick={copy} data-testid={testId ? `${testId}-copy` : undefined}>{copied ? 'Copied' : `Copy ${label.toLowerCase()}`}</button></p>
    </div>
  );
}
