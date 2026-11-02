'use client';
import '@/styles/push.css';
import { useState, useTransition } from 'react';
import { savePushTopics, sendTestPush } from '@/server/actions/push';
import { storeLink, topicLabel, topicsFor, type PushRole, type PushState, type Topic } from './topics';
import { usePushDevice } from './usePushDevice';

// Phone and browser alerts (migration 0300): the card on each portal's profile (Admin: Settings > My phone alerts).
// Turn alerts on or off for this device, choose what alerts, see the other devices, send a test.

export function ShareIcon() {
  return (
    <svg className="pa-share" viewBox="0 0 20 20" width="16" height="16" aria-hidden="true" focusable="false">
      <path d="M10 2.5v10M6.5 6 10 2.5 13.5 6" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M6 9H4.5v8.5h11V9H14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  );
}

export function IosSteps() {
  return (
    <ol className="pa-steps" data-testid="push-ios-steps">
      <li><span>Open carmacars.ca in Safari and tap <b>Share</b> <ShareIcon />.</span></li>
      <li><span>Tap <b>Add to Home Screen</b>, then <b>Add</b>.</span></li>
      <li><span>Open CarmaCars from your Home Screen, sign in and turn alerts on here.</span></li>
    </ol>
  );
}

const fmt = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' });

export function PushAlertsCard({ publicKey, portal, initial, className = 'pt-card' }: { publicKey: string; portal: PushRole; initial: PushState; className?: string }) {
  const d = usePushDevice(publicKey, portal, initial);
  const state = d.state ?? initial;
  const [topics, setTopics] = useState<Topic[]>(state.topics);
  const [saved, setSaved] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const on = d.status === 'on';
  // the app is in the stores: phones download it instead of the browser steps (never when this device already has alerts on)
  const app = !on && d.status !== 'loading' && typeof navigator !== 'undefined' ? storeLink(navigator.userAgent, state.store, navigator.maxTouchPoints) : null;
  const shown = topicsFor(state.role);
  const others = state.devices.filter((x) => x.device && x.id && !(on && x.this));

  const toggle = (t: Topic, checked: boolean) => {
    const was = topics;
    const next = checked ? [...topics, t] : topics.filter((x) => x !== t);
    setTopics(next); setSaved(null);
    start(async () => {
      const r = await savePushTopics(next);
      if (!r.ok) { setTopics(was); d.setError(r.message); return; }
      d.setState(r.data); setSaved('Saved.');
    });
  };
  const test = () => start(async () => {
    setSaved(null);
    const r = await sendTestPush();
    if (!r.ok) { d.setError(r.message); return; }
    setSaved(r.data.queued ? 'Test alert sent. It should arrive in a few seconds.' : 'No device has alerts on yet.');
  });

  return (
    <section className={`${className} pa`} aria-labelledby="pa-title" data-testid="push-card" data-status={d.status}>
      <div className="pa__head">
        <h2 className="d4" id="pa-title">Phone alerts</h2>
        {d.status !== 'loading' && <span className={`badge ${on ? 'badge--red' : 'badge--outline'}`} data-testid="push-badge">{on ? 'On' : 'Off'} on this device</span>}
      </div>
      <p className="small muted pa__lead">Get an alert on this phone or computer the moment something needs you, even with CarmaCars closed.</p>

      {d.status === 'loading' && <p className="small muted" aria-live="polite">Checking this browser…</p>}

      {app && (
        <div className="pa__callout" data-testid="push-app">
          <p className="pa__callout-title">Download the CarmaCars app for alerts</p>
          <p className="small muted">The app alerts you the moment something needs you, even when it is closed.</p>
          <a className="btn btn--primary" href={app.url} data-testid="push-app-link">{app.platform === 'ios' ? 'Get it on the App Store' : 'Get it on Google Play'}</a>
        </div>
      )}
      {!app && d.status === 'ios_install' && (
        <div className="pa__callout" data-testid="push-ios">
          <p className="pa__callout-title">On iPhone and iPad, add CarmaCars to your Home Screen first</p>
          <IosSteps />
          <p className="small muted">Apple allows alerts only from apps on the Home Screen (iOS 16.4 or later).</p>
        </div>
      )}
      {d.status === 'blocked' && (
        <p className="pt-note" data-testid="push-blocked">Alerts are blocked for this site. Allow notifications for carmacars.ca in your browser&apos;s site settings, then reload this page.</p>
      )}
      {d.status === 'unsupported' && (
        <p className="pt-note" data-testid="push-unsupported">This browser cannot show alerts. Use Chrome, Edge, Firefox or Safari, or add CarmaCars to your Home Screen.</p>
      )}
      {!app && d.status === 'ready' && (
        <div className="pa__action">
          <button type="button" className="btn btn--primary" onClick={() => void d.turnOn()} disabled={d.busy} data-testid="push-on">{d.busy ? 'Turning on…' : 'Turn on alerts'}</button>
          <span className="small muted">Your browser asks once. You can turn them off at any time.</span>
        </div>
      )}
      {on && (
        <div className="pa__action">
          <button type="button" className="btn btn--ghost btn--sm" onClick={test} disabled={pending || d.busy} data-testid="push-test">Send a test alert</button>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => void d.turnOff()} disabled={d.busy} data-testid="push-off">Turn off on this device</button>
        </div>
      )}

      <fieldset className="pa__topics" disabled={pending} data-testid="push-topics">
        <legend className="label pa__legend">What to alert me about{saved === 'Saved.' && <span className="pa__saved" role="status" data-testid="push-saved">Saved</span>}</legend>
        <div className="pa__grid">
          {shown.map((t) => {
            const w = topicLabel(state.role, t);
            return (
              <label className="option pa__opt" key={t}>
                <input type="checkbox" role="switch" checked={topics.includes(t)} onChange={(e) => toggle(t, e.target.checked)} data-testid={`push-topic-${t}`} />
                <span className="option__title">{w.label}</span>
                <span className="option__body">{w.hint}</span>
              </label>
            );
          })}
        </div>
        <p className="hint">{state.chosen ? 'Your choice applies to all your devices.' : 'Set for your role. Your choice applies to all your devices.'} Sign-in links and codes never come as alerts.</p>
      </fieldset>

      {others.length > 0 && (
        <div className="pa__devices">
          <p className="label">{on ? 'Your other devices' : 'Your devices with alerts on'}</p>
          <ul className="pa__list" data-testid="push-devices">
            {others.map((x) => (
              <li key={x.id}>
                <span><b>{x.device}</b>{x.this && <span className="badge badge--grey pa__this">This device</span>}<span className="small muted pa__since">Since {fmt(x.created_at)}</span></span>
                <button type="button" className="btn btn--quiet btn--sm" onClick={() => void d.removeDevice(x.id)} disabled={d.busy} aria-label={`Remove ${x.device}`}>Remove</button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {((saved && saved !== 'Saved.') || d.error) && (
        <p className={d.error ? 'alert alert--error' : 'alert alert--ok'} role={d.error ? 'alert' : 'status'} data-testid="push-msg"><span>{d.error ?? saved}</span></p>
      )}
    </section>
  );
}
