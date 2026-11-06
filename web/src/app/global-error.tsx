'use client';
import { useEffect } from 'react';
import { reportClientError } from '@/lib/client-error/report';

// The whole frame crashed (0433): a minimal page of its own, reported to Admin.
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => { reportClientError(error, error.digest); }, [error]);
  return (
    <html lang="en-CA">
      <body style={{ margin: 0, fontFamily: 'Inter, Arial, sans-serif', background: '#0b0b0b', color: '#fff' }}>
        <main style={{ maxWidth: 560, margin: '0 auto', padding: '64px 16px' }}>
          {/* the brand logo (release 28); this page has no site frame around it */}
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages, @next/next/no-img-element */}
          <a href="/" aria-label="CarmaCars home"><img src="/brand/carma-logo-white.svg" width={170} height={30} alt="CarmaCars" style={{ display: 'block', marginBottom: 40 }} /></a>
          <h1 style={{ fontSize: 32, margin: '0 0 12px' }}>Something went wrong.</h1>
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
