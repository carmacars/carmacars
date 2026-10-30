import type { ReactNode } from 'react';
import { InfoTip } from '@/components/InfoTip';
import { infoText } from '@/features/info/text';

// The field of prototype/DESIGN.md: label, input, hint, error tied with aria-describedby.
// float: the label sits inside the input until it has a value or focus (src/styles/motion.css); the input needs placeholder=" ".
// info (Release 21b): the "i" beside the label, a key of src/features/info/text.ts or the text itself
export function Field({ id, label, error, hint, optional, children, className = '', float = false, info }: { id: string; label: ReactNode; error?: string; hint?: ReactNode; optional?: boolean; children: ReactNode; className?: string; float?: boolean; info?: string }) {
  const tipText = info ? (infoText(info) ?? info) : undefined;
  return (
    <div className={`field${float ? ' field--float' : ''}${error ? ' has-error' : ''}${className ? ' ' + className : ''}`}>
      {tipText && !float
        ? <span className="label-line"><label className="label" htmlFor={id}>{label}{optional && <> <span className="opt">optional</span></>}</label><InfoTip text={tipText} topic={typeof label === 'string' ? label : undefined} testId={`info-${id}`} /></span>
        : <label className="label" htmlFor={id}>{label}{optional && <> <span className="opt">optional</span></>}</label>}
      {children}
      {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-err`}>{error ?? ''}</p>
    </div>
  );
}
export const describedBy = (id: string, error?: string, hint?: boolean) => [hint ? `${id}-hint` : '', error ? `${id}-err` : ''].filter(Boolean).join(' ') || undefined;
