'use client';
import { useRef, useState, useTransition } from 'react';
import { DateInput } from '@/components/DateInput';
import type { ActionResult } from '@/features/forms/schemas';
import { applyChange, CADENCES, CHANNELS, channelNote, clockWords, minutesToTime, summaryLine, switchKey, timeToMinutes, type Channel, type PrefChange, type PrefState, type PrefType } from './prefs';

// The Notifications page of every portal (release 48, migration 3260; the owner, Nov 20: "EVERYONE can customise their
// notifications"): each kind of notification with a switch per channel (push, email, text), quiet hours, and instant, a
// daily summary or a weekly one. The kinds marked Always on cannot be switched off (security codes, legal and agreement
// notices, charges, receipts, booking confirmations and changes, return reminders; for staff, assigned work and
// onboarding or suspension notices). A switch moves at once and is saved in the background; a refusal puts it back and
// says why. `save` is the portal's own server action (the signed-in person; an Admin for someone else; a partner's link).
type Save = (change: PrefChange) => Promise<ActionResult<PrefState>>;

function Lock() {
  return <svg className="rw-lock" viewBox="0 0 20 20" aria-hidden="true"><path d="M5.5 9V6.5a4.5 4.5 0 019 0V9M4 9h12v8H4z" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" /></svg>;
}

function Row({ t, s, busy, onSwitch, idp }: { t: PrefType; s: PrefState; busy: Set<string>; onSwitch: (t: PrefType, c: Channel, on: boolean) => void; idp: string }) {
  return (
    <li className="rw-pref" data-testid={`${idp}-type-${t.code}`} data-locked={t.locked || undefined}>
      <div className="rw-pref__what">
        <p className="rw-pref__label">{t.label}</p>
        {t.detail && <p className="rw-pref__detail">{t.detail}</p>}
        {!t.live && <p className="rw-pref__soon" data-testid={`${idp}-soon-${t.code}`}>Starts when your tracker is installed. Your choice is kept.</p>}
      </div>
      {t.locked
        ? <p className="rw-pref__locked"><Lock /><span>Always on</span></p>
        : <div className="rw-pref__switches" role="group" aria-label={t.label}>
            {CHANNELS.map((c) => {
              const has = t.channels.includes(c.key);
              const k = switchKey(t.code, c.key);
              const cannot = c.key === 'email' ? !s.channels.email.address : !s.channels[c.key].on;
              return (
                <label key={c.key} className="switch rw-switch" data-none={!has || undefined} aria-busy={busy.has(k) || undefined}>
                  <span className="rw-switch__name">{c.label}</span>
                  {has
                    ? <input type="checkbox" role="switch" checked={t[c.key]} disabled={busy.has(k) || cannot} aria-label={`${t.label}: ${c.label}`}
                        onChange={(e) => onSwitch(t, c.key, e.target.checked)} data-testid={`${idp}-${t.code}-${c.key}`} />
                    : <span className="rw-switch__none" aria-label={`${c.label}: not sent this way`}>n/a</span>}
                </label>
              );
            })}
          </div>}
    </li>
  );
}

export function NotificationPrefs({ initial, save, idp = 'np' }: { initial: PrefState; save: Save; idp?: string }) {
  const [s, setS] = useState(initial);
  const [busy, setBusy] = useState<Set<string>>(new Set());
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [, start] = useTransition();
  const saved = useRef(initial);
  const [from, setFrom] = useState(minutesToTime(initial.profile.quiet_from));
  const [until, setUntil] = useState(minutesToTime(initial.profile.quiet_until));

  const send = (change: PrefChange, key: string, done = 'Saved.') => {
    setS((cur) => applyChange(cur, change));
    setBusy((b) => new Set(b).add(key));
    setMsg(null);
    start(async () => {
      let r: ActionResult<PrefState>;
      try { r = await save(change); } catch { r = { ok: false, code: 'failed', message: 'Not saved. Check your connection and try again.' }; }
      setBusy((b) => { const n = new Set(b); n.delete(key); return n; });
      if (r.ok) { saved.current = r.data; setS(r.data); setMsg({ ok: true, text: done }); }
      else { setS(saved.current); setMsg({ ok: false, text: r.message }); }
    });
  };
  const quietTime = (which: 'quiet_from' | 'quiet_until', v: string) => {
    const m = timeToMinutes(v);
    if (m === null) return;
    send({ [which]: m } as PrefChange, which);
  };
  const notes = CHANNELS.map((c) => ({ ...c, note: channelNote(s, c.key) })).filter((c) => c.note);
  const optional = s.groups.filter((g) => !g.locked);
  const locked = s.groups.filter((g) => g.locked);

  return (
    <div className="rw-prefs stack-lg" data-testid={`${idp}-prefs`} data-portal={s.portal}>
      <p className="rw-prefs__summary" data-testid={`${idp}-summary`}>{summaryLine(s)}</p>
      {notes.length > 0 && (
        <ul className="rw-prefs__notes" aria-label="About your channels">
          {notes.map((c) => <li key={c.key} data-testid={`${idp}-note-${c.key}`}><b>{c.label}.</b> {c.note}</li>)}
        </ul>
      )}
      <p className="rw-prefs__status" role="status" aria-live="polite" data-ok={msg?.ok ?? undefined} data-testid={`${idp}-status`}>{msg?.text ?? ''}</p>

      {s.kind === 'user' && (
        <section className="pt-card stack" aria-labelledby={`${idp}-how`}>
          <h3 className="d4" id={`${idp}-how`}>How often</h3>
          <div className="seg rw-seg" role="radiogroup" aria-label="How often optional emails arrive">
            {CADENCES.map((c) => (
              <label key={c.key}><input type="radio" name={`${idp}-cadence`} value={c.key} checked={s.profile.cadence === c.key} disabled={busy.has('cadence')}
                onChange={() => send({ cadence: c.key }, 'cadence')} data-testid={`${idp}-cadence-${c.key}`} /><span>{c.label}</span></label>
            ))}
          </div>
          <p className="small muted">{CADENCES.find((c) => c.key === s.profile.cadence)?.hint} The kinds marked Always on come at once, whatever you choose.</p>
          <div className="rw-quiet">
            <label className="switch"><input type="checkbox" role="switch" checked={s.profile.quiet_on} disabled={busy.has('quiet_on')}
              onChange={(e) => send({ quiet_on: e.target.checked }, 'quiet_on')} data-testid={`${idp}-quiet-on`} /><span><b>Quiet hours</b></span></label>
            <div className="rw-quiet__times" data-off={!s.profile.quiet_on || undefined}>
              <div className="field"><label className="label" htmlFor={`${idp}-qf`}>From</label>
                <DateInput id={`${idp}-qf`} type="time" value={from} disabled={!s.profile.quiet_on} onChange={(e) => { setFrom(e.target.value); if (timeToMinutes(e.target.value) !== s.profile.quiet_from) quietTime('quiet_from', e.target.value); }} data-testid={`${idp}-quiet-from`} /></div>
              <div className="field"><label className="label" htmlFor={`${idp}-qu`}>Until</label>
                <DateInput id={`${idp}-qu`} type="time" value={until} disabled={!s.profile.quiet_on} onChange={(e) => { setUntil(e.target.value); if (timeToMinutes(e.target.value) !== s.profile.quiet_until) quietTime('quiet_until', e.target.value); }} data-testid={`${idp}-quiet-until`} /></div>
            </div>
            <p className="small muted">{s.profile.quiet_on ? `Optional phone alerts and texts wait from ${clockWords(s.profile.quiet_from)} until ${clockWords(s.profile.quiet_until)}, Toronto time.` : 'Optional phone alerts and texts wait until morning while quiet hours are on.'}</p>
          </div>
          <label className="switch rw-alloff"><input type="checkbox" role="switch" checked={s.profile.all_off} disabled={busy.has('all_off')}
            onChange={(e) => send({ all_off: e.target.checked }, 'all_off', e.target.checked ? 'Every optional notification is off.' : 'Your own choices are back on.')} data-testid={`${idp}-all-off`} />
            <span><b>Turn every optional notification off</b><small>You still see them in your portal. The kinds marked Always on still reach you.</small></span></label>
        </section>
      )}

      {optional.map((g) => (
        <section key={g.name} className="pt-card stack" aria-label={g.name} data-testid={`${idp}-group`}>
          <div className="rw-prefs__head"><h3 className="d4">{g.name}</h3>
            <p className="rw-prefs__cols" aria-hidden="true">{CHANNELS.map((c) => <span key={c.key}>{c.label}</span>)}</p></div>
          <ul className="rw-preflist" data-dim={s.profile.all_off || undefined}>
            {g.types.map((t) => <Row key={t.code} t={t} s={s} busy={busy} idp={idp} onSwitch={(x, c, on) => send({ type: x.code, channel: c, on }, switchKey(x.code, c))} />)}
          </ul>
        </section>
      ))}
      {optional.length === 0 && <div className="pt-empty"><p className="d4">Nothing optional here.</p><p className="muted">Everything this account gets is listed below and is always sent.</p></div>}

      {locked.map((g) => (
        <section key={g.name} className="pt-card stack rw-prefs__lockedcard" aria-label={g.name} data-testid={`${idp}-locked`}>
          <h3 className="d4">Always on</h3>
          <p className="small muted">These are about your security, your agreements, your money{s.portal === 'renter' ? ' and your booking' : s.staff ? ' and the work assigned to you' : ''}. They cannot be switched off.</p>
          <ul className="rw-preflist">{g.types.map((t) => <Row key={t.code} t={t} s={s} busy={busy} idp={idp} onSwitch={() => undefined} />)}</ul>
        </section>
      ))}
    </div>
  );
}
