'use client';
import { ErrorPanel } from '@/lib/client-error/ErrorPanel';

// r49 polish (reel 10, error states): a page inside a portal that crashed keeps the portal around it (the side nav, the
// tabs, the account menu) instead of falling through to the site's full-screen error page. The panel is the site's own
// (src/lib/client-error/ErrorPanel.tsx: the crash reported to Admin, Try again, the phone and email), in a portal card.
export function PortalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <section className="pt-card ui-card portal-error" data-testid="portal-error">
      <ErrorPanel error={error} reset={reset} />
    </section>
  );
}
