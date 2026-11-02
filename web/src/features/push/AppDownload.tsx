'use client';
import { useSyncExternalStore } from 'react';
import type { AppLinks } from '@/lib/site';

// "Download the CarmaCars app" (migration 0523): on a phone browser only, with its own store's link, once the link is
// set in Program settings (app_store_url, play_store_url). Never inside the app (web-only), never on a computer, and
// nothing in the server render (the phone is known in the browser only).
const noop = () => () => undefined;
export function phoneStore(ua: string, apps: AppLinks): string | null {
  if (/CarmaCarsApp\//.test(ua)) return null;
  if (/iPhone|iPad|iPod/.test(ua)) return apps.ios;
  if (/Android/.test(ua)) return apps.android;
  return null;
}

export function AppDownload({ apps, className = '' }: { apps: AppLinks; className?: string }) {
  const href = useSyncExternalStore(noop, () => phoneStore(navigator.userAgent, apps), () => null);
  if (!href) return null;
  return (
    <p className={`app-dl web-only ${className}`.trim()} data-testid="app-download">
      <a className="btn btn--ghost btn--sm" href={href} rel="noopener" target="_blank">Download the CarmaCars app</a>
    </p>
  );
}
