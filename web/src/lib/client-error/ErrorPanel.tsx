'use client';
import { useEffect, useState } from 'react';
import { reportClientError } from './report';
import { causeOf, dialable, readContact, recoverInBrowser, retryDelayS } from './recover';

// The crashed page's panel (r27b, the owner on November 6: "Try again and Reload just fail again, and it says call or text
// us with no number"). It says whose problem it is: our servers busy (it then tries again by itself, waiting longer each
// time), a newer version of the site (it reloads once), or something on this device (Try again and Reload). The phone
// number (tap to call or text) and the email come from Site settings (the layout's cc-contact meta tag). What people
// typed is kept: the forms save as they type. Used by app/error.tsx (every page, Admin and staff too) and app/global-error.tsx.
const KEY = 'cc-busy-retry';
function nextAttempt(path: string): number {
  try {
    const o = JSON.parse(sessionStorage.getItem(KEY) ?? 'null') as { p: string; n: number; t: number } | null;
    const n = o && o.p === path && Date.now() - o.t < 10 * 60_000 ? o.n + 1 : 0;
    sessionStorage.setItem(KEY, JSON.stringify({ p: path, n, t: Date.now() }));
    return n;
  } catch { return 0; }
}

export function ErrorPanel({ error, reset, plain = false }: { error: Error & { digest?: string }; reset: () => void; plain?: boolean }) {
  const [cause] = useState(() => causeOf(error));
  const [contact, setContact] = useState(readContact(null));
  const [left, setLeft] = useState<number | null>(null);
  useEffect(() => {
    queueMicrotask(() => setContact(readContact(document)));
    // r46: a page of an older deploy reloads once and is not a crash; reported only when it cannot reload (twice in a minute)
    if (cause === 'stale' && recoverInBrowser(error)) return;
    reportClientError(error, error.digest);
    if (cause === 'stale') return;
    if (cause !== 'server') return;
    const n = nextAttempt(window.location.pathname);
    const until = Date.now() + retryDelayS(n) * 1000;
    const tick = () => {
      const s = Math.max(0, Math.ceil((until - Date.now()) / 1000));
      setLeft(s);
      if (s === 0) window.location.reload();
    };
    const id = window.setInterval(tick, 1000);
    queueMicrotask(tick);
    return () => window.clearInterval(id);
  }, [error, cause]);

  const title = cause === 'server' ? 'Our servers are busy right now.' : cause === 'stale' ? 'The site was just updated.' : 'Something went wrong on this page.';
  const lead = cause === 'server'
    ? `This is on our side, not your device. ${left === null ? 'Trying again shortly.' : left > 0 ? `Trying again by itself in ${left} seconds.` : 'Trying again now.'}`
    : cause === 'stale' ? 'Loading the new version of this page.' : 'This page hit an error on your device. Try again, or reload the page.';
  const tel = dialable(contact.phone);
  const s = plain
    ? { p: { color: '#c9c9c9', lineHeight: 1.5 } as React.CSSProperties, a: { color: '#fff' } as React.CSSProperties, btn: { background: '#d0111b', color: '#fff', border: 0, padding: '12px 18px', borderRadius: 6, fontSize: 16 } as React.CSSProperties,
        ghost: { background: 'transparent', color: '#fff', border: '1px solid #fff', padding: '12px 18px', borderRadius: 6, fontSize: 16 } as React.CSSProperties }
    : null;
  return (
    <div className={plain ? undefined : 'stack'} data-testid="error-panel" data-cause={cause}>
      <h1 className={plain ? undefined : 'd1'} style={plain ? { fontSize: 32, margin: '0 0 12px' } : undefined}>{title}</h1>
      <p className={plain ? undefined : 'lead muted'} style={s?.p} role="status" aria-live="polite">{lead} What you typed is kept.</p>
      <p className={plain ? undefined : 'muted'} style={s?.p}>
        Need us now? Call or text <a href={`tel:${tel}`} style={s?.a} className={plain ? undefined : 'link'}>{contact.phone}</a>
        {' '}(<a href={`sms:${tel}`} style={s?.a} className={plain ? undefined : 'link'}>text</a>) or email <a href={`mailto:${contact.email}`} style={s?.a} className={plain ? undefined : 'link'}>{contact.email}</a>.
      </p>
      <p className={plain ? undefined : 'row'} style={plain ? { display: 'flex', gap: 12, flexWrap: 'wrap' } : undefined}>
        <button type="button" className={plain ? undefined : 'btn btn--primary btn--lg'} style={s?.btn} onClick={() => (cause === 'server' ? window.location.reload() : reset())}>Try again now</button>
        <a className={plain ? undefined : 'btn btn--ghost btn--lg'} style={s?.ghost} href={`tel:${tel}`}>Call {contact.phone}</a>
      </p>
    </div>
  );
}
