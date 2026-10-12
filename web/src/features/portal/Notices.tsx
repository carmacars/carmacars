'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { markRead, setMarketing, setPreference } from '@/server/actions/portal';
import type { Notice, NoticePref } from './types';
import { useAct } from './useAct';

export function NoticeList({ items }: { items: Notice[] }) {
  const router = useRouter();
  const a = useAct();
  const unread = items.filter((n) => !n.read_at);
  if (!items.length) return <div className="pt-empty"><p className="d4">No notifications yet.</p><p className="muted">Offers, payments and pickup details appear here and by email.</p></div>;
  return (
    <div className="stack">
      {unread.length > 0 && <div><button className="btn btn--ghost btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => markRead(null), () => router.refresh())}>Mark all as read</button></div>}
      <ul className="pt-notes">
        {items.map((n) => (
          <li key={n.id} className={n.read_at ? '' : 'is-unread'}>
            <div className="stack" style={{ gap: 'var(--s-1)' }}>
              <p className="pt-notes__title">{n.title}{!n.read_at && <span className="vh"> (unread)</span>}</p>
              {n.body && <p className="small muted">{n.body}</p>}
              <p className="xs muted">{new Date(n.created_at).toLocaleString('en-CA', { timeZone: 'America/Toronto', dateStyle: 'medium', timeStyle: 'short' })}</p>
              <div className="row">
                {n.url && /^\/(?!\/)/.test(n.url) && <a className="link" href={n.url}>Open</a>}
                {!n.read_at && <button className="btn btn--quiet btn--sm" type="button" onClick={() => a.run(() => markRead([n.id]), () => router.refresh())}>Mark as read</button>}
              </div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

export function Preferences({ prefs, marketing, marketingText }: { prefs: NoticePref[]; marketing: boolean; marketingText: string }) {
  const router = useRouter();
  const a = useAct();
  const [mk, setMk] = useState(marketing);
  const mutable = prefs.filter((p) => p.user_can_mute);
  return (
    <div className="stack-lg">
      <div className="stack">
        <label className="check">
          <input type="checkbox" checked={mk} onChange={(e) => { const v = e.target.checked; setMk(v); a.run(() => setMarketing(v), () => router.refresh()); }} />
          <span><b>CarmaCars offers and news by email.</b> {marketingText}</span>
        </label>
        <p className="small muted">Booking, payment and safety messages are always sent.</p>
      </div>
      {mutable.length > 0 && (
        <div className="pt-prefs" role="group" aria-label="Optional messages">
          {mutable.map((p) => (
            <div key={p.code}>
              <span>{p.subject}</span>
              <label className="check"><input type="checkbox" checked={p.email_enabled} onChange={(e) => a.run(() => setPreference(p.code, e.target.checked, p.in_app_enabled), () => router.refresh())} /><span>Email</span></label>
              <label className="check"><input type="checkbox" checked={p.in_app_enabled} onChange={(e) => a.run(() => setPreference(p.code, p.email_enabled, e.target.checked), () => router.refresh())} /><span>Here</span></label>
            </div>
          ))}
        </div>
      )}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
    </div>
  );
}
