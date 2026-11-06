'use client';
import { ErrorPanel } from '@/lib/client-error/ErrorPanel';

// The whole frame crashed (0433; r27b): a minimal page of its own, reported to Admin, with the same panel as every page,
// and the brand logo (release 28) since this page has no site frame around it.
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <html lang="en-CA">
      <body style={{ margin: 0, fontFamily: 'Inter, Arial, sans-serif', background: '#0b0b0b', color: '#fff' }}>
        <main style={{ maxWidth: 560, margin: '0 auto', padding: '64px 16px' }}>
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages, @next/next/no-img-element */}
          <a href="/" aria-label="CarmaCars home"><img src="/brand/carma-logo-white.svg" width={170} height={30} alt="CarmaCars" style={{ display: 'block', marginBottom: 40 }} /></a>
          <ErrorPanel error={error} reset={reset} plain />
        </main>
      </body>
    </html>
  );
}
