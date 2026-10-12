import type { ReactNode } from 'react';

// The field of prototype/DESIGN.md: label, input, hint, error tied with aria-describedby.
export function Field({ id, label, error, hint, optional, children, className = '' }: { id: string; label: ReactNode; error?: string; hint?: ReactNode; optional?: boolean; children: ReactNode; className?: string }) {
  return (
    <div className={`field${error ? ' has-error' : ''}${className ? ' ' + className : ''}`}>
      <label className="label" htmlFor={id}>{label}{optional && <> <span className="opt">optional</span></>}</label>
      {children}
      {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-err`}>{error ?? ''}</p>
    </div>
  );
}
export const describedBy = (id: string, error?: string, hint?: boolean) => [hint ? `${id}-hint` : '', error ? `${id}-err` : ''].filter(Boolean).join(' ') || undefined;
