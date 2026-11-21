'use client';
import { useEffect, useState } from 'react';
import { haptic } from '@/lib/native/bridge';
import { stateLine, type MyLocation } from '@/features/live-map/people';
import { act, permission, readState, startWatch } from './share';

// Settings > Privacy: Location on the live map (migration 3350, release 48 part MAP). Everyone: whether it is shared now
// and why, the switch (on by default; staff cannot turn it off during an active job) and Allow on this device (the phone's
// or the browser's own question). Staff: the electronic monitoring policy (Ontario ESA Part XI.1), accepted once; their copy
// is emailed. Renters and owners: shared only two hours either side of a pickup or return.
const when = (iso: string) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: 'long', day: 'numeric' });

export function LocationCard({ initial, className = 'pt-card' }: { initial: MyLocation | null; className?: string }) {
  const [s, setS] = useState<MyLocation | null>(initial);
  const [busy, setBusy] = useState<'' | 'policy' | 'switch' | 'allow'>('');
  const [done, setDone] = useState<'' | 'policy' | 'switch' | 'allow'>('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [perm, setPerm] = useState<'granted' | 'prompt' | 'denied' | 'unknown'>('unknown');

  useEffect(() => {
    let live = true;
    void permission().then((p) => { if (live) setPerm(p); });
    if (!initial) void readState().then((x) => { if (live) setS(x); });
    return () => { live = false; };
  }, [initial]);
  useEffect(() => { if (!done) return; const t = setTimeout(() => setDone(''), 1600); return () => clearTimeout(t); }, [done]);

  if (!s || !s.kind) return null;
  const staff = s.kind === 'staff';
  const accepted = !!s.policy?.accepted_at;

  const run = async (what: 'policy' | 'switch', body: Record<string, unknown>, ok: string) => {
    setBusy(what); setMsg(null);
    // the switch moves at once (a controlled box otherwise stays put until the database answers); put back on a refusal
    const before = s;
    if (what === 'switch') setS({ ...s, sharing_on: body.sharing_on !== false });
    const r = await act(what === 'policy' ? 'policy' : 'prefs', body);
    setBusy('');
    if (!r.ok) { if (what === 'switch') setS(before); setMsg({ ok: false, text: r.message }); haptic('error'); return; }
    setS({ ...s, ...r.data }); setDone(what); setMsg({ ok: true, text: ok }); haptic('success');
  };
  const allow = () => {
    setBusy('allow'); setMsg(null);
    const stop = startWatch(() => { stop?.(); setBusy(''); setPerm('granted'); setDone('allow'); setMsg({ ok: true, text: 'Allowed on this device.' }); haptic('success'); },
      (m) => { stop?.(); setBusy(''); setPerm('denied'); setMsg({ ok: false, text: `${m} Allow it in the settings for this site or app, then try again.` }); }, true);
    if (!stop) setBusy('');
  };

  return (
    <section className={`${className} pa`} id="location" aria-labelledby="loc-title" data-testid="location-card">
      <div className="pa__head"><h2 className="d4" id="loc-title">Location on the live map</h2></div>
      <p className="small" role="status" data-testid="location-state">{stateLine(s)}</p>
      {staff && s.policy && !accepted && (
        <div className="stack" data-testid="location-policy">
          <p className="pt-note">{s.policy.text}</p>
          <p><button type="button" className="btn btn--primary btn--sm" disabled={!!busy} aria-busy={busy === 'policy'}
            onClick={() => void run('policy', { version: s.policy!.version }, 'Accepted. Your copy of the policy is on its way by email.')} data-testid="location-accept">
            {busy === 'policy' ? 'Saving…' : 'I have read it and accept'}</button></p>
        </div>
      )}
      {staff && accepted && <p className="small muted" data-testid="location-policy-done">Electronic monitoring policy accepted on {when(s.policy!.accepted_at!)}. Your copy was emailed to you and is always sent (it cannot be turned off).</p>}
      <div className="pa__grid">
        <label className="option pa__opt">
          <input type="checkbox" role="switch" checked={s.sharing_on !== false} disabled={!!busy || (s.locked && s.sharing_on !== false)} data-testid="location-switch"
            onChange={(e) => void run('switch', { sharing_on: e.target.checked }, e.target.checked ? 'On.' : 'Off. Nothing is shared.')} />
          <span className="option__title">Share my location</span>
          <span className="option__body">{staff
            ? (s.locked ? 'On during an active job; you can turn it off once the job is done.' : 'Only while you are on shift or on a job, never off duty. Admins and Fleet see it.')
            : 'Only two hours either side of your pickup or return, so the team can meet you. Never otherwise.'}</span>
        </label>
      </div>
      {perm !== 'granted' && s.sharing_on !== false && (
        <p><button type="button" className="btn btn--ghost btn--sm" disabled={!!busy} aria-busy={busy === 'allow'} onClick={allow} data-testid="location-allow">
          {busy === 'allow' ? 'Asking…' : done === 'allow' ? 'Allowed' : 'Allow on this device'}</button></p>
      )}
      <p className="small muted">We keep only where you are now, plus the points of each job, pickup or return for 30 days. No history.</p>
      {msg && <p className={`small ${msg.ok ? 'muted' : 'alert alert--error'}`} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
    </section>
  );
}
