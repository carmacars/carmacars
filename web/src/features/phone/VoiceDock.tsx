'use client';
import './phone.css';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { answer, decline, dismiss, hangUp, sendDigit, startVoice, subscribeVoice, toggleMute, voiceState, type VoiceState } from './voice';

// The browser's phone bar (release 44, migration 2790), on every page of the staff and Admin portals: an incoming call to
// the CarmaCars number (Answer, Decline), a call being placed, the call itself (timer, Mute, Keypad, Hang up) and what
// went wrong. Nothing shows while there is no call. quiet: viewing as someone else (no phone at all).

const IDLE: VoiceState = { phase: 'idle' };
const clock = (ms: number) => { const s = Math.max(0, Math.floor(ms / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };

export function VoiceDock({ quiet }: { quiet?: boolean }) {
  const st = useSyncExternalStore(subscribeVoice, voiceState, () => IDLE);
  const [now, setNow] = useState(() => Date.now());
  const [pad, setPad] = useState(false);
  useEffect(() => { if (!quiet) startVoice(); }, [quiet]);
  useEffect(() => {
    if (st.phase !== 'in_call') return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [st.phase]);
  if (quiet || st.phase === 'idle') return null;
  const who = st.who ?? 'A caller';
  return (
    <section className="vd" aria-label="Phone" data-testid="voice-dock" data-phase={st.phase}>
      {st.phase === 'ringing_in' && <>
        <p className="vd-line" role="status"><b>Incoming call</b> <span>{who}</span></p>
        <p className="vd-acts"><button type="button" className="btn btn--primary btn--sm" onClick={answer} data-testid="voice-answer">Answer</button>
          <button type="button" className="btn btn--ghost btn--sm" onClick={decline} data-testid="voice-decline">Decline</button></p>
      </>}
      {(st.phase === 'starting' || st.phase === 'calling') && <>
        <p className="vd-line" role="status"><b>Calling {who}</b> <span className="muted">from the CarmaCars number</span></p>
        <p className="vd-acts">{st.phase === 'calling' && <button type="button" className="btn btn--primary btn--sm" onClick={hangUp} data-testid="voice-hangup">Hang up</button>}</p>
      </>}
      {st.phase === 'in_call' && <>
        <p className="vd-line" role="status"><b>{who}</b> <span className="vd-time">{clock(now - (st.since ?? now))}</span></p>
        <p className="vd-acts">
          <button type="button" className="btn btn--ghost btn--sm" aria-pressed={!!st.muted} onClick={toggleMute} data-testid="voice-mute">{st.muted ? 'Unmute' : 'Mute'}</button>
          <button type="button" className="btn btn--ghost btn--sm" aria-expanded={pad} onClick={() => setPad(!pad)}>Keypad</button>
          <button type="button" className="btn btn--primary btn--sm" onClick={() => { setPad(false); hangUp(); }} data-testid="voice-hangup">Hang up</button>
        </p>
        {pad && st.phase === 'in_call' && <p className="vd-pad">{['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'].map((d) => <button key={d} type="button" className="btn btn--quiet btn--sm" onClick={() => sendDigit(d)}>{d}</button>)}</p>}
      </>}
      {st.phase === 'problem' && <>
        <p className="vd-line alert alert--warn small" role="alert" data-testid="voice-problem"><span>{st.message ?? 'The call did not go through.'}</span></p>
        <p className="vd-acts"><button type="button" className="btn btn--ghost btn--sm" onClick={dismiss}>Close</button></p>
      </>}
    </section>
  );
}
