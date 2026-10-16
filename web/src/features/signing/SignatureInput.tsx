'use client';
import { useEffect, useState } from 'react';
import { SignaturePad } from '@/features/portal/SignaturePad';

// The signature, as simply as it can be given (migration 0049): the person's legal name on file, shown as a signature,
// is adopted with one tap on Sign (a typed signature: the name is recorded as typed, with the time, IP address and
// device). Drawing with a finger stays one tap away. A wrong name is fixed where it is kept (the Fix link).
export type SignatureValue = { method: 'typed'; typedName: string } | { method: 'drawn'; png: string } | null;

export function SignatureInput({ id, name, onChange, invalid, describedBy, fixHref, defaultMode = 'adopt' }: {
  id: string; name: string; onChange: (v: SignatureValue) => void; invalid?: boolean; describedBy?: string; fixHref?: string; defaultMode?: 'adopt' | 'draw';
}) {
  const [mode, setMode] = useState<'adopt' | 'draw'>(name.trim() ? defaultMode : 'draw');
  useEffect(() => {
    if (mode === 'adopt') onChange(name.trim() ? { method: 'typed', typedName: name } : null);
    else onChange(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, name]);
  return (
    <div className="stack" data-testid="signature-input" data-mode={mode}>
      <div className="sigpad__tools">
        <span className="label" id={`${id}-label`}>{mode === 'adopt' ? 'Your signature' : 'Draw your signature'}</span>
        {name.trim() && <button type="button" className="btn btn--quiet btn--sm" onClick={() => setMode(mode === 'adopt' ? 'draw' : 'adopt')} data-testid="signature-mode">
          {mode === 'adopt' ? 'Draw instead' : 'Use my name instead'}</button>}
      </div>
      {mode === 'adopt' ? (
        <div className={`sig-adopt${invalid ? ' is-invalid' : ''}`} id={id} data-testid="signature-adopted">
          <span className="sig-adopt__name" role="img" aria-label={`Your signature: ${name}`} aria-describedby={describedBy}>{name}</span>
          <span className="sig-adopt__hint small muted">Your full legal name, as on file. {fixHref ? <a className="link" href={fixHref}>Not right? Fix it</a> : null}</span>
        </div>
      ) : (
        <SignaturePad id={id} onChange={(png) => onChange(png ? { method: 'drawn', png } : null)} invalid={invalid} describedBy={describedBy} />
      )}
    </div>
  );
}
