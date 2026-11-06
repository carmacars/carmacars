'use client';
import { useEffect, useState } from 'react';
import { reportClientError } from '@/lib/client-error/report';
import { recoverInBrowser } from '@/lib/client-error/recover';

// The whole frame crashed (0433): a minimal page of its own, reported to Admin.
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  // r27b: a page of an older deploy or a server render that failed (the database busy) reloads once by itself
  const [reloading, setReloading] = useState(false);
  useEffect(() => { reportClientError(error, error.digest); if (recoverInBrowser(error)) queueMicrotask(() => setReloading(true)); }, [error]);
  return (
    <html lang="en-CA">
      <body style={{ margin: 0, fontFamily: 'Inter, Arial, sans-serif', background: '#0b0b0b', color: '#fff' }}>
        <main style={{ maxWidth: 560, margin: '0 auto', padding: '64px 16px' }}>
          <h1 style={{ fontSize: 32, margin: '0 0 12px' }}>{reloading ? 'One moment, reloading the page.' : 'Something went wrong.'}</h1>
          <p style={{ color: '#c9c9c9', lineHeight: 1.5 }}>The page hit an error on your device. Your progress is saved. Try again, and if it happens again call or text us and we will finish it with you. We have been told about it.</p>
          <p style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
            <button type="button" onClick={() => reset()} style={{ background: '#d0111b', color: '#fff', border: 0, padding: '12px 18px', borderRadius: 6, fontSize: 16 }}>Try again</button>
            <button type="button" onClick={() => window.location.reload()} style={{ background: 'transparent', color: '#fff', border: '1px solid #fff', padding: '12px 18px', borderRadius: 6, fontSize: 16 }}>Reload the page</button>
          </p>
        </main>
      </body>
    </html>
  );
}
