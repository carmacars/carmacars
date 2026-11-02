'use client';
import { haptic, share } from '@/lib/native/bridge';

// Share a car (migration 0390): the phone's share sheet, in the store app only (app-only: hidden in browsers, where the
// browser's own share is one tap away). Shares the car's page on carmacars.ca, which opens in the app for anyone who
// has it.
export function ShareButton({ title, path, className = 'btn btn--quiet btn--sm' }: { title: string; path: string; className?: string }) {
  return (
    <button type="button" className={`${className} app-only`} data-testid="app-share"
      onClick={async () => { if (await share({ title, text: `${title} on CarmaCars`, url: new URL(path, location.origin).toString() })) haptic('success'); }}>
      <svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true" focusable="false" style={{ marginRight: '0.4em', verticalAlign: '-0.2em' }}>
        <path d="M10 2.5v10M6.5 6 10 2.5 13.5 6" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
        <path d="M6 9H4.5v8.5h11V9H14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
      Share
    </button>
  );
}
