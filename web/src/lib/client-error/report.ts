// Sends a browser crash to /api/client-error (migration 0433). Never throws; at most 5 reports per page load.
let sent = 0;
export function reportClientError(e: unknown, digest?: string): void {
  if (typeof window === 'undefined' || sent >= 5) return;
  sent += 1;
  const err = e instanceof Error ? e : new Error(typeof e === 'string' ? e : 'Unknown error');
  const body = JSON.stringify({ message: err.message || String(e), stack: err.stack ?? '', digest: digest ?? (err as { digest?: string }).digest, path: window.location.pathname });
  try {
    if (navigator.sendBeacon) { navigator.sendBeacon('/api/client-error', new Blob([body], { type: 'application/json' })); return; }
  } catch { /* fall through */ }
  void fetch('/api/client-error', { method: 'POST', headers: { 'content-type': 'application/json' }, body, keepalive: true }).catch(() => undefined);
}
