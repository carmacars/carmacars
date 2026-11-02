'use client';
import { useEffect } from 'react';
import { reportClientError } from './report';

// Uncaught errors and rejected promises in any page (0433). Noise that is not a crash is left out: the stale build
// guard handles chunk errors, and ResizeObserver loop notices and cancelled requests are harmless.
const NOISE = /ResizeObserver loop|ChunkLoadError|Loading chunk|Loading CSS chunk|AbortError|The user aborted|cancelled|Load failed/i;
export function ClientErrorListener() {
  useEffect(() => {
    const onError = (ev: ErrorEvent) => { const m = ev.error instanceof Error ? ev.error.message : ev.message; if (!m || NOISE.test(m)) return; reportClientError(ev.error ?? m); };
    const onRejection = (ev: PromiseRejectionEvent) => { const r = ev.reason; const m = r instanceof Error ? r.message : String(r ?? ''); if (!m || NOISE.test(m)) return; reportClientError(r); };
    window.addEventListener('error', onError);
    window.addEventListener('unhandledrejection', onRejection);
    return () => { window.removeEventListener('error', onError); window.removeEventListener('unhandledrejection', onRejection); };
  }, []);
  return null;
}
