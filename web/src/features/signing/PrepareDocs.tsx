'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';

// The sign page's documents are shown from their text at once; the PDFs the signature is recorded against are made
// here, one request per document (POST /api/sign/prepare, migration 0075), then the page reloads its data with the
// signing form. A failure says so, with Try again; nothing on the page breaks.
// how many times this browser tab prepared and reloaded without the documents opening (a guard against a loop)
let cycles = 0;

export type PrepTarget = { t: 'packet'; key: string } | { t: 'form'; code: 'A' | 'B' } | { t: 'partner' } | { t: 'form_c'; vehicle: string };

export function PrepareDocs({ targets, titles, testId = 'prepare-docs' }: { targets: PrepTarget[]; titles: string[]; testId?: string }) {
  const router = useRouter();
  const [done, setDone] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [run, setRun] = useState(0);
  const busy = useRef(false);

  const go = useCallback(async () => {
    if (busy.current) return;
    busy.current = true;
    setError(null);
    try {
      for (let i = 0; i < targets.length; i++) {
        let last = '';
        let ok = false;
        // one automatic retry after two seconds, then the person decides
        for (let attempt = 0; attempt < 2 && !ok; attempt++) {
          if (attempt) await new Promise((r) => setTimeout(r, 2000));
          try {
            const r = await fetch('/api/sign/prepare', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(targets[i]) });
            const j = (await r.json().catch(() => ({}))) as { ok?: boolean; message?: string };
            if (r.ok && j.ok) ok = true;
            else last = j.message ?? `The server answered ${r.status}.`;
            if (r.status === 401 || r.status === 403) break;
          } catch { last = 'Your connection dropped.'; }
        }
        if (!ok) { setError(last || 'We could not prepare the documents.'); return; }
        setDone(i + 1);
      }
      cycles++;
      if (cycles > 3) { setError('The documents were prepared but the page did not pick them up.'); return; }
      router.refresh();
    } finally { busy.current = false; }
  }, [targets, router]);

  useEffect(() => { void go(); }, [go, run]);

  return (
    <div className="stack" data-testid={testId} aria-live="polite">
      {error ? (
        <div className="alert alert--error stack" role="alert" data-testid={`${testId}-error`}>
          <span className="alert__title">The documents are not ready yet</span>
          <span>{error} Your details are safe; nothing was signed. Try again, or call us if it keeps happening.</span>
          <div className="row"><button type="button" className="btn btn--primary btn--sm" onClick={() => { cycles = 0; setRun((n) => n + 1); }} data-testid={`${testId}-retry`}>Try again</button></div>
        </div>
      ) : (
        <p className="small" role="status">
          Preparing your documents for signature{targets.length > 1 ? ` (${Math.min(done + 1, targets.length)} of ${targets.length})` : ''}. This takes a few seconds; read them meanwhile.
        </p>
      )}
      <ul className="small muted">{titles.map((t, i) => <li key={t + i}>{t}{i < done ? ': ready' : ''}</li>)}</ul>
    </div>
  );
}
