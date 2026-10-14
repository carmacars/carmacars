'use client';
import { usePathname } from 'next/navigation';
import { useSyncExternalStore } from 'react';

// The red banner while an Admin views CarmaCars as someone else (src/server/view-as.ts). It reads the name from the
// banner cookie (cc-view-as-ui, which carries no authority) so cached public pages can show it too. Exit is a plain
// form, so it works before the page's script runs.
function readName(): string | null {
  const m = document.cookie.split(';').map((c) => c.trim()).find((c) => c.startsWith('cc-view-as-ui='));
  if (!m) return null;
  try { return decodeURIComponent(m.slice('cc-view-as-ui='.length)) || null; } catch { return null; }
}

const noop = () => () => {};
const serverName = () => null;

export function ViewAsBanner() {
  const path = usePathname();
  // the server renders no banner (the page may be cached for everyone); the browser reads the cookie on each render
  const name = useSyncExternalStore(noop, readName, serverName);
  if (!name) return null;
  const admin = path === '/admin' || path.startsWith('/admin/');
  return (
    <div className="viewas" role="region" aria-label="Viewing as" data-testid="view-as-banner">
      <div className="viewas__in">
        <span>{admin ? <>You are viewing other portals as {name}. Here in Admin you are yourself.</> : <>Viewing as {name}, read only.</>}</span>
        <form method="post" action="/api/view-as/exit"><button className="btn btn--sm" type="submit" data-testid="view-as-exit">Exit</button></form>
      </div>
    </div>
  );
}
