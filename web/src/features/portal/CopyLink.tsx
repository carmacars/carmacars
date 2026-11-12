'use client';
import { useState } from 'react';

/** done: the words once copied ("Link copied" by default; r40 uses it for a code too). */
export function CopyLink({ url, label, done: doneLabel = 'Link copied', testId, ariaLabel }: { url: string; label: string; done?: string; testId?: string; ariaLabel?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" className="btn btn--ghost btn--sm" data-testid={testId} aria-label={ariaLabel} aria-live="polite" onClick={() => { navigator.clipboard?.writeText(url).then(() => setDone(true)).catch(() => setDone(false)); }}>
      {done ? doneLabel : label}
    </button>
  );
}
