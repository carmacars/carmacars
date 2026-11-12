'use client';
import { useEffect } from 'react';
import { reportClientError } from './report';

import { NOISE, foreignError } from './noise';

// Uncaught errors and rejected promises in any page (0433). Noise that is not a crash is left out (noise.ts), and so are
// errors thrown by scripts that are not ours (r40: extensions and autofill on form pages).
export function ClientErrorListener() {
  useEffect(() => {
    const o = window.location.origin;
    const onError = (ev: ErrorEvent) => { const m = ev.error instanceof Error ? ev.error.message : ev.message; if (!m || NOISE.test(m)) return;
      if (foreignError(o, ev.filename, ev.error instanceof Error ? ev.error.stack : '')) return; reportClientError(ev.error ?? m); };
    const onRejection = (ev: PromiseRejectionEvent) => { const r = ev.reason; const m = r instanceof Error ? r.message : String(r ?? ''); if (!m || NOISE.test(m)) return;
      if (r instanceof Error && foreignError(o, null, r.stack)) return; reportClientError(r); };
    window.addEventListener('error', onError);
    window.addEventListener('unhandledrejection', onRejection);
    return () => { window.removeEventListener('error', onError); window.removeEventListener('unhandledrejection', onRejection); };
  }, []);
  return null;
}
