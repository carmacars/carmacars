'use client';
import '@/styles/push.css';
import Link from '@/components/Link';
import { usePathname } from 'next/navigation';
import { useState, useSyncExternalStore } from 'react';
import { ShareIcon } from './PushAlertsCard';
import type { PushRole } from './topics';
import { usePushDevice } from './usePushDevice';

// Phone and browser alerts (migration 0300): one short invitation on each portal's first page, on a device that can
// show alerts and has not been asked. "Not now" hides it for 30 days on this device. Never shown to automation (a
// crawler or a test browser), and never while an Admin views a portal as someone else (the layout leaves it out).
const KEY = 'cc-push-prompt';
const QUIET_DAYS = 30;

const WHAT: Record<PushRole, string> = {
  renter: 'Your offer, pickup details and our messages, the moment they happen.',
  owner: 'New bookings of your cars, payouts and incidents, the moment they happen.',
  investor: 'Returns paid and new statements, the moment they are ready.',
  staff: 'New requests, replies to answer and urgent alerts, the moment they happen.',
  field: 'New and changed jobs, the moment they are assigned.',
  admin: 'New requests, payments, messages and urgent alerts, the moment they happen.'
};
export const SETTINGS: Record<PushRole, string> = {
  renter: '/account/profile', owner: '/owner/profile', investor: '/investor/profile', staff: '/staff/profile', field: '/staff/field/profile', admin: '/admin/alerts'
};

const noop = () => () => undefined;
function dismissed(): boolean {
  try { const t = Number(localStorage.getItem(KEY)); return t > 0 && Date.now() - t < QUIET_DAYS * 86_400_000; } catch { return false; }
}

export function PushPrompt({ publicKey, portal, home }: { publicKey: string; portal: PushRole; home: string | string[] }) {
  const path = usePathname();
  const homes = Array.isArray(home) ? home : [home];
  // asked on this device in the last 30 days, or a test browser: no invitation (the server render never has one)
  const quiet = useSyncExternalStore(noop, () => dismissed() || navigator.webdriver === true, () => true);
  const [closed, setHidden] = useState(false);
  const [done, setDone] = useState(false);
  const d = usePushDevice(publicKey, portal, null, { readState: false });
  if (!homes.includes(path) || quiet || closed || d.status === 'loading') return null;
  if (!done && !(d.status === 'ready' || d.status === 'ios_install')) return null;
  const notNow = () => { try { localStorage.setItem(KEY, String(Date.now())); } catch { /* private mode */ } setHidden(true); };

  if (done) {
    return (
      <aside className="pa-prompt pa-prompt--done" aria-label="Phone alerts" data-testid="push-prompt">
        <span className="pa-prompt__icon" aria-hidden="true"><Bell /></span>
        <div className="pa-prompt__text" role="status"><p className="pa-prompt__title">Alerts are on for this device</p>
          <p className="small">Choose what alerts you in <Link prefetch={false} className="link" href={SETTINGS[portal]}>your settings</Link>.</p></div>
        <div className="pa-prompt__actions"><button type="button" className="btn btn--quiet btn--sm" onClick={() => setHidden(true)}>Close</button></div>
      </aside>
    );
  }
  const ios = d.status === 'ios_install';
  return (
    <aside className="pa-prompt" aria-label="Phone alerts" data-testid="push-prompt">
      <span className="pa-prompt__icon" aria-hidden="true"><Bell /></span>
      <div className="pa-prompt__text">
        <p className="pa-prompt__title">{ios ? 'Get CarmaCars alerts on your iPhone' : 'Get alerts on this device'}</p>
        <p className="small">{ios ? <>Tap <b>Share</b> <ShareIcon /> then <b>Add to Home Screen</b>. Open CarmaCars from there to turn alerts on.</> : WHAT[portal]}</p>
        {d.error && <p className="small pa-prompt__error" role="alert">{d.error}</p>}
      </div>
      <div className="pa-prompt__actions">
        {!ios && <button type="button" className="btn btn--primary btn--sm" disabled={d.busy} onClick={async () => { if (await d.turnOn()) setDone(true); }} data-testid="push-prompt-on">{d.busy ? 'Turning on…' : 'Turn on'}</button>}
        <button type="button" className="btn btn--quiet btn--sm" onClick={notNow} data-testid="push-prompt-later">Not now</button>
      </div>
    </aside>
  );
}

function Bell() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" focusable="false">
      <path d="M6 16.5V11a6 6 0 1 1 12 0v5.5l1.5 2h-15z" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
      <path d="M10 20.5a2 2 0 0 0 4 0" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  );
}
