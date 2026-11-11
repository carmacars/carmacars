'use client';
import { useEffect, useRef, useState } from 'react';
import { BEAT_EVENTS, beatDue, nudgeDue } from './model';

// 1800: the inactivity tracker of the office staff, on every page of the staff portal. A real interaction (a pointer, a
// key, a scroll, focus) sends one beat a minute at most to /api/staff/activity: the fact only, never the key, the page or
// the screen. Nothing is sent from a hidden tab. While counted (clocked in, not on a break) a gentle "Still there?" shows
// after the nudge minutes without interaction; any interaction hides it. The clock card tells it at once when the person
// clocks in or out or starts or ends a break (TrackingSignal); each beat's answer says it too.
const EVT = 'cc-va-tracking';
type Signal = { tracking: boolean; nudgeMinutes: number };

export function TrackingSignal(p: Signal) {
  useEffect(() => { window.dispatchEvent(new CustomEvent<Signal>(EVT, { detail: p })); }, [p.tracking, p.nudgeMinutes]); // eslint-disable-line react-hooks/exhaustive-deps
  return null;
}

export function ActivityBeat() {
  const st = useRef({ tracking: true, nudge: 8, lastSent: 0, lastActive: 0, sending: false });
  const [nudge, setNudge] = useState(false);
  useEffect(() => {
    const s = st.current;
    s.lastActive = Date.now();
    const send = () => {
      if (s.sending || document.visibilityState !== 'visible') return;
      s.sending = true; s.lastSent = Date.now();
      fetch('/api/staff/activity', { method: 'POST', keepalive: true }).then((r) => (r.ok ? r.json() : null)).then((v: { tracking?: boolean; nudge_minutes?: number } | null) => {
        if (v && typeof v.tracking === 'boolean') s.tracking = v.tracking;
        if (v && typeof v.nudge_minutes === 'number') s.nudge = v.nudge_minutes;
      }).catch(() => undefined).finally(() => { s.sending = false; });
    };
    const act = () => {
      s.lastActive = Date.now();
      setNudge(false);
      if (beatDue(s.lastSent, s.lastActive, s.tracking)) send();
    };
    const signal = (e: Event) => {
      const d = (e as CustomEvent<Signal>).detail;
      const was = s.tracking;
      s.tracking = d.tracking; s.nudge = d.nudgeMinutes;
      if (d.tracking && !was) { s.lastActive = Date.now(); s.lastSent = 0; }
      if (!d.tracking) setNudge(false);
    };
    for (const t of BEAT_EVENTS) window.addEventListener(t, act, { passive: true, capture: true });
    window.addEventListener(EVT, signal);
    const tick = setInterval(() => setNudge(nudgeDue(s.lastActive, Date.now(), s.nudge, s.tracking, document.visibilityState === 'visible')), 15_000);
    return () => { for (const t of BEAT_EVENTS) window.removeEventListener(t, act, { capture: true }); window.removeEventListener(EVT, signal); clearInterval(tick); };
  }, []);
  if (!nudge) return null;
  return (
    <div className="pt-card small row" role="status" data-testid="va-still-there" style={{ position: 'fixed', insetInline: 'var(--s-3)', bottom: 'var(--s-3)', zIndex: 60, maxWidth: '28rem', marginInline: 'auto' }}>
      <span>Still there? </span><button type="button" className="btn btn--sm btn--primary">I&apos;m here</button>
    </div>
  );
}
