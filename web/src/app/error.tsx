'use client';
import { ErrorPanel } from '@/lib/client-error/ErrorPanel';

// A page that crashed (0433; r27b): our own message instead of a blank screen, the crash reported to Admin, whose problem
// it is, an automatic retry when our servers are busy, and the phone and email (src/lib/client-error/ErrorPanel.tsx).
export default function PageError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <section className="nf on-dark">
      <div className="wrap nf__in">
        <ErrorPanel error={error} reset={reset} />
      </div>
    </section>
  );
}
