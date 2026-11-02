'use client';
import { useEffect } from 'react';
import { reportClientError } from '@/lib/client-error/report';

// A page that crashed (0433): our own message instead of a blank screen, the crash reported to Admin, and a way back.
// Forms save as people type, so "Try again" usually keeps their progress.
export default function PageError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => { reportClientError(error, error.digest); }, [error]);
  return (
    <section className="nf on-dark">
      <div className="wrap nf__in">
        <div className="stack">
          <h1 className="d1">Something went wrong.</h1>
          <p className="lead muted">This page hit an error on your device. Your progress is saved. Try again, and if it happens again call or text us and we will finish it with you. We have been told about it.</p>
          <p className="row">
            <button type="button" className="btn btn--primary btn--lg" onClick={() => reset()}>Try again</button>
            <button type="button" className="btn btn--ghost btn--lg" onClick={() => window.location.reload()}>Reload the page</button>
          </p>
        </div>
      </div>
    </section>
  );
}
