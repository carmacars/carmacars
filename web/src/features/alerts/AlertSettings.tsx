'use client';
import '@/styles/push.css';
import '@/styles/alerts.css';
import { useState, useTransition } from 'react';
import { saveAlertPrefs } from '@/server/actions/alerts';
import { clock, HALF_HOURS, type AlertPrefs } from './types';

// The staff alert settings (migration 0466): quiet hours (non-urgent phone alerts wait until they end) and focus mode
// (only urgent alerts reach the phone for a while). Everything still shows in the Alerts feed.
const until = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'America/Toronto' });

export function AlertSettings({ initial, className = 'pt-card stack' }: { initial: AlertPrefs; className?: string }) {
  const [p, setP] = useState(initial);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [now, setNow] = useState(() => Date.now());
  const save = (change: Parameters<typeof saveAlertPrefs>[0], done: string) => start(async () => {
    setMsg(null); setErr(null);
    const r = await saveAlertPrefs(change);
    if (!r.ok) { setErr(r.message); return; }
    setP(r.data); setMsg(done); setNow(Date.now());
  });
  const focus = p.focus_until && new Date(p.focus_until).getTime() > now ? p.focus_until : null;

  return (
    <section className={`${className} as`} aria-labelledby="as-title" data-testid="alert-settings">
      <h2 className="d4" id="as-title">When alerts reach my phone</h2>

      <div className="as__block" data-testid="alert-quiet">
        <label className="option pa__opt as__switch">
          <input type="checkbox" role="switch" checked={p.quiet_on} disabled={pending} onChange={(e) => save({ quiet_on: e.target.checked, quiet_from: p.quiet_from, quiet_until: p.quiet_until }, e.target.checked ? 'Quiet hours on.' : 'Quiet hours off.')} data-testid="alert-quiet-on" />
          <span className="option__title">Quiet hours</span>
          <span className="option__body">Non-urgent alerts wait until the quiet hours end. Urgent ones always come at once.</span>
        </label>
        <div className="as__times">
          <label className="field as__time"><span className="label">From</span>
            <select className="input" value={p.quiet_from} disabled={pending || !p.quiet_on} onChange={(e) => save({ quiet_on: true, quiet_from: Number(e.target.value), quiet_until: p.quiet_until }, 'Saved.')} data-testid="alert-quiet-from">
              {HALF_HOURS.map((m) => <option key={m} value={m}>{clock(m)}</option>)}
            </select></label>
          <label className="field as__time"><span className="label">Until</span>
            <select className="input" value={p.quiet_until} disabled={pending || !p.quiet_on} onChange={(e) => save({ quiet_on: true, quiet_from: p.quiet_from, quiet_until: Number(e.target.value) }, 'Saved.')} data-testid="alert-quiet-until">
              {HALF_HOURS.map((m) => <option key={m} value={m}>{clock(m)}</option>)}
            </select></label>
        </div>
      </div>

      <div className="as__block" data-testid="alert-focus">
        <p className="as__label"><b>Focus mode</b> <span className={`badge ${focus ? 'badge--red' : 'badge--outline'}`} data-testid="alert-focus-state" suppressHydrationWarning>{focus ? `On until ${until(focus)}` : 'Off'}</span></p>
        <p className="small muted">Only urgent alerts reach your phone; the rest wait in Alerts.</p>
        <div className="as__row">
          <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => save({ focus_minutes: 60 }, 'Focus mode on for 1 hour.')} data-testid="alert-focus-60">1 hour</button>
          <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => save({ focus_minutes: 180 }, 'Focus mode on for 3 hours.')} data-testid="alert-focus-180">3 hours</button>
          {focus && <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => save({ focus_minutes: 0 }, 'Focus mode off.')} data-testid="alert-focus-off">Turn off</button>}
        </div>
      </div>

      {(msg || err) && <p className={err ? 'alert alert--error' : 'alert alert--ok'} role={err ? 'alert' : 'status'} data-testid="alert-settings-msg"><span>{err ?? msg}</span></p>}
    </section>
  );
}
