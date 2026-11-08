'use client';

// One portal card of "Choose a portal" (0720): a plain link that also remembers the portal chosen for next time (a
// cookie holding the portal's key only, read by the page to put it first).
export function PortalCardLink({ portal, cookie, className, href, children }: { portal: string; cookie: string; className: string; href: string; children: React.ReactNode }) {
  return (
    <a className={className} href={href} data-portal={portal} data-testid={`portal-card-${portal}`}
      onClick={() => { try { document.cookie = `${cookie}=${portal};path=/;max-age=31536000;samesite=lax`; } catch { /* cookies off: the order stays the usual one */ } }}>
      {children}
    </a>
  );
}
