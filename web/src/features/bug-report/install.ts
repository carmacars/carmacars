'use client';
import { Ring, type LogEntry } from './logs';

// Release 37 (2340): the last 50 console errors and warnings, crashes and failed calls of this tab, kept in memory only
// (never sent anywhere until the person sends a bug report). Installed once when a portal's frame loads. Redacted as they
// are kept (logs.ts): no query strings, no emails, numbers, keys or tokens; each message capped.
const KEY = '__ccBugRing';
type W = Window & { [KEY]?: Ring };

export function installBugRing(): void {
  if (typeof window === 'undefined') return;
  const w = window as W;
  if (w[KEY]) return;
  const ring = new Ring();
  w[KEY] = ring;
  for (const level of ['error', 'warn'] as const) {
    const orig = console[level].bind(console); // eslint-disable-line no-console
    console[level] = (...args: unknown[]) => { // eslint-disable-line no-console
      try { ring.push({ kind: level, msg: args.map((a) => (a instanceof Error ? `${a.name}: ${a.message}` : typeof a === 'string' ? a : (() => { try { return JSON.stringify(a); } catch { return String(a); } })())).join(' ') }); } catch { /* never break logging */ }
      orig(...args);
    };
  }
  window.addEventListener('error', (e) => { try { ring.push({ kind: 'crash', msg: e.error ?? e.message, url: e.filename || undefined }); } catch { /* ignore */ } });
  window.addEventListener('unhandledrejection', (e) => { try { ring.push({ kind: 'rejection', msg: e.reason }); } catch { /* ignore */ } });
  const origFetch = window.fetch.bind(window);
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    const method = init?.method ?? (input instanceof Request ? input.method : 'GET');
    try {
      const res = await origFetch(input, init);
      if (!res.ok && res.status !== 304) {
        try { ring.push({ kind: 'fetch', msg: `${res.status} ${res.statusText}`.trim(), url, status: res.status, method, ray: res.headers.get('cf-ray') ?? undefined }); } catch { /* ignore */ }
      }
      return res;
    } catch (err) {
      if (!(err instanceof DOMException && err.name === 'AbortError')) {
        try { ring.push({ kind: 'fetch', msg: err, url, method, status: 0 }); } catch { /* ignore */ }
      }
      throw err;
    }
  };
}

/** What the ring holds now (oldest first). */
export function bugRingEntries(): LogEntry[] {
  if (typeof window === 'undefined') return [];
  return (window as W)[KEY]?.list() ?? [];
}
