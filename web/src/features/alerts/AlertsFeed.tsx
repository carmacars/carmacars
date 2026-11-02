'use client';
import '@/styles/alerts.css';
import Link from '@/components/Link';
import { useState, useTransition } from 'react';
import { markAlertsRead, snoozeAlert } from '@/server/actions/alerts';
import { ago, FILTERS, TIER_LABEL, type AlertFilter, type AlertItem } from './types';

// The staff Alerts feed (migration 0466), behind the bell of the Admin and staff portals: every alert of the person,
// newest first. Opening one marks it read; urgent ones can be snoozed for 30 minutes (the phone alert comes again then
// and its escalation waits).
const hhmm = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'America/Toronto' });

export function AlertsFeed({ initial, filter, base }: { initial: AlertItem[]; filter: AlertFilter; base: string }) {
  const [items, setItems] = useState(initial);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [now] = useState(() => Date.now());
  const unread = items.filter((x) => !x.read_at).length;

  const read = (ids: string[] | null) => {
    const now = new Date().toISOString();
    setItems((xs) => xs.map((x) => (ids === null || ids.includes(x.id) ? { ...x, read_at: x.read_at ?? now } : x)));
    start(async () => { const r = await markAlertsRead(ids); if (!r.ok) setMsg(r.message); });
  };
  const snooze = (id: string) => start(async () => {
    const r = await snoozeAlert(id, 30);
    if (!r.ok) { setMsg(r.message); return; }
    setItems((xs) => xs.map((x) => (x.id === id ? { ...x, snoozed_until: r.data } : x)));
    setMsg(r.data ? `Snoozed until ${hhmm(r.data)}. It comes again then.` : 'Already read.');
  });

  return (
    <section className="al" aria-labelledby="al-title" data-testid="alerts-feed">
      <div className="al__bar">
        <h2 className="vh" id="al-title">Alerts</h2>
        <nav className="al__filters" aria-label="Show">
          {FILTERS.map(([f, label]) => (
            <Link prefetch={false} scroll={false} key={f} href={f === 'all' ? base : `${base}?f=${f}`} className="al__chip" aria-current={f === filter ? 'page' : undefined} data-testid={`alerts-filter-${f}`}>{label}</Link>
          ))}
        </nav>
        <span className="al__right">
          {unread > 0 && <span className="al__count" data-testid="alerts-unread">{unread} unread</span>}
          {unread > 0 && <button type="button" className="btn btn--quiet btn--sm al__all" onClick={() => read(null)} disabled={pending} data-testid="alerts-read-all">Mark all read</button>}
        </span>
      </div>
      {msg && <p className="small al__msg" role="status">{msg}</p>}
      {items.length === 0 ? (
        <p className="al__empty" data-testid="alerts-empty">{filter === 'unread' ? 'Nothing unread. You are up to date.' : filter === 'urgent' ? 'No urgent alerts.' : 'No alerts yet. New leads, requests, payments and anything urgent show here.'}</p>
      ) : (
        <ul className="al__list" data-testid="alerts-list">
          {items.map((x) => (
            <li key={x.id} className={`al__item al__item--${x.tier}${x.read_at ? '' : ' is-unread'}`} data-testid="alert-item" data-tier={x.tier}>
              <span className="al__dot" aria-hidden="true" />
              <div className="al__main">
                <Link prefetch={false} href={x.url || '/'} className="al__title" onClick={() => { if (!x.read_at) read([x.id]); }}>
                  {!x.read_at && <span className="vh">Unread: </span>}{x.title}
                </Link>
                {x.body && <p className="al__body">{x.body}</p>}
                <p className="al__meta">
                  <span className={`al__tier al__tier--${x.tier}`}>{TIER_LABEL[x.tier]}</span>
                  <span>{x.group}</span>
                  <time dateTime={x.created_at} suppressHydrationWarning>{ago(x.created_at, now)}</time>
                  {x.snoozed_until && !x.read_at && new Date(x.snoozed_until).getTime() > now && <span suppressHydrationWarning>Snoozed until {hhmm(x.snoozed_until)}</span>}
                </p>
              </div>
              {!x.read_at && (
                <div className="al__acts">
                  {x.tier === 'urgent' && <button type="button" className="btn btn--ghost btn--sm" onClick={() => snooze(x.id)} disabled={pending} data-testid="alert-snooze">Snooze 30 min</button>}
                  <button type="button" className="btn btn--quiet btn--sm" onClick={() => read([x.id])} disabled={pending} data-testid="alert-read">Mark read</button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
