'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldClock, type ClockLoc } from '@/server/actions/field';
import { elapsedClock } from '@/features/field-pay/model';
import { clockText, type OpenMust, type Today } from './model';

// The top of Today (r35 part X): the shift, one Clock in or Clock out, and how much of the day's must-dos is done. Clock out with
// must-dos still open asks a reason for each first (0930; Fleet is told). The phone's location is read at the tap only (0881).
const here = () => new Promise<ClockLoc | null>((resolve) => {
  if (typeof navigator === 'undefined' || !navigator.geolocation) { resolve(null); return; }
  navigator.geolocation.getCurrentPosition(
    (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: p.coords.accuracy, located_at: new Date(p.timestamp).toISOString() }),
    () => resolve(null), { enableHighAccuracy: true, timeout: 10_000, maximumAge: 0 });
});

export function ShiftStrip({ t, open }: { t: Today; open: OpenMust[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const [why, setWhy] = useState('');
  const [askWhy, setAskWhy] = useState(false);
  const [closing, setClosing] = useState(false);
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { if (!t.clock) return; const x = setInterval(() => setNow(Date.now()), 30_000); return () => clearInterval(x); }, [t.clock]);
  const go = (what: 'in' | 'out') => start(async () => {
    setMsg(null);
    if (what === 'out' && open.length > 0 && !closing) { setClosing(true); return; }
    const loc = await here();
    const r = await fieldClock(what, null, loc, why, what === 'out' && open.length ? reasons : null);
    if (!r.ok) { setMsg(r.message); if (/location is needed|clocking here/i.test(r.message)) setAskWhy(true); return; }
    setWhy(''); setAskWhy(false); setClosing(false); setReasons({});
    router.refresh();
  });
  const pct = t.counts.must ? Math.round((t.counts.done / t.counts.must) * 100) : 0;
  return (
    <section className="fp-shift" aria-labelledby="fp-shift-h" data-testid="shift-strip">
      <div className="fp-shift__row">
        <div><p className="fp-shift__label" id="fp-shift-h">{t.shift ? 'Your shift today' : 'No shift today'}</p>
          {t.shift ? <p className="fp-shift__time">{clockText(t.shift.starts_at)} to {clockText(t.shift.ends_at)}</p> : <p className="small">Claim one on My shifts. Jobs go to people on a shift.</p>}</div>
        {t.clock && <div style={{ textAlign: 'right' }}><p className="fp-shift__label">Clocked in</p><p className="fp-shift__clock" data-testid="clock-elapsed">{elapsedClock(t.clock.started_at, now)}</p></div>}
      </div>
      {t.counts.must > 0 && <div className="fp-meter" aria-label="Must-dos done">
        <p className="fp-meter__text"><span>{t.counts.done} of {t.counts.must} done</span><span>{pct}%</span></p>
        <div className="fp-meter__bar"><span style={{ width: `${pct}%` }} /></div></div>}
      {askWhy && <div className="field"><label className="label" htmlFor="fp-why">Why (your location is off, or you are away from the lot)</label>
        <input id="fp-why" className="input" value={why} maxLength={300} onChange={(e) => setWhy(e.target.value)} data-testid="clock-reason" /></div>}
      {closing && <div className="fp-open" data-testid="clock-open-items"><h3>Still open: give a reason for each</h3>
        <p className="small">Fleet is told, so someone can cover them.</p>
        {open.map((o) => <div key={o.key} className="field"><label className="label" htmlFor={`why-${o.key}`}>{o.label}</label>
          <input id={`why-${o.key}`} className="input" value={reasons[o.key] ?? ''} maxLength={300} onChange={(e) => setReasons({ ...reasons, [o.key]: e.target.value })} placeholder="For example: the renter is late, Fleet knows" /></div>)}
        <button type="button" className="btn btn--ghost fd-wide" onClick={() => setClosing(false)} disabled={pending}>Keep working</button></div>}
      {t.clock
        ? <button type="button" className={`btn ${closing ? 'btn--primary' : 'btn--ghost'} fd-wide`} data-testid="clock-out" disabled={pending} onClick={() => go('out')}>{pending ? 'Working' : closing ? 'Clock out with these reasons' : 'Clock out'}</button>
        : <button type="button" className="btn btn--primary fd-wide" data-testid="clock-in" disabled={pending} onClick={() => go('in')}>{pending ? 'Working' : 'Clock in'}</button>}
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
    </section>
  );
}
