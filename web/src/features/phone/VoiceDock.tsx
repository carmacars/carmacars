'use client';
import './phone.css';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { answer, audioDevices, chooseMicrophone, chooseSpeaker, decline, dismiss, hangUp, openDialer, placeCall, sendDigit, startVoice, subscribeVoice,
  toggleHold, toggleMute, voiceContacts, voiceState, type AudioDevices, type VoiceContact, type VoiceState } from './voice';
import { e164, prettyNumber } from './quo-links';

// The browser's phone (release 44, migration 2790), on every page of the staff and Admin portals. r50 hotfix 2: a call
// screen like a phone's own: the contact's name and number, the timer, round buttons (Mute, Keypad, Speaker, Hold), the
// microphone choice and a red End button; Answer and Decline for an incoming call; a keypad dialer to call any number
// (the round Phone button at the bottom left when there is no call) and the person's contacts (5092). On a phone the screen covers the page; on a computer
// it is a card at the bottom left (the caller pop-up keeps the bottom right). quiet: viewing as someone else (no phone).

const IDLE: VoiceState = { phase: 'idle' };
const KEYS: Array<[string, string]> = [['1', ''], ['2', 'ABC'], ['3', 'DEF'], ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'], ['7', 'PQRS'], ['8', 'TUV'], ['9', 'WXYZ'], ['*', ''], ['0', '+'], ['#', '']];
const clock = (ms: number) => { const s = Math.max(0, Math.floor(ms / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
const initial = (who: string) => (who.replace(/[^A-Za-z]/g, '').charAt(0) || '#').toUpperCase();

const Ic = ({ d }: { d: string }) => <svg viewBox="0 0 24 24" aria-hidden="true" className="vc-ic"><path d={d} /></svg>;
const PHONE = 'M8.2 3.5 5.6 4.2c-1 .3-1.6 1.2-1.5 2.2.8 7.3 6.6 13.1 13.9 13.9 1 .1 2-.5 2.2-1.5l.7-2.6-4-1.8-1.8 1.9a11 11 0 0 1-5.5-5.5l1.9-1.8z';
const MIC = 'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3';
const MIC_OFF = 'M4 4l16 16M9 9v3a3 3 0 0 0 5 2.2M15 11V6a3 3 0 0 0-5.8-1M5.5 11.5a6.5 6.5 0 0 0 10.4 5.2M18.5 11.5a6.4 6.4 0 0 1-.6 2.7M12 18v3';
const PAD = 'M6 5h.01M12 5h.01M18 5h.01M6 11h.01M12 11h.01M18 11h.01M6 17h.01M12 17h.01M18 17h.01';
const SPEAKER = 'M4 9.5h3.5L12 5.5v13l-4.5-4H4zM15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11';
const HOLD = 'M9 5v14M15 5v14';
const BACK = 'M9 6h11v12H9l-5-6zM12.5 9.5l5 5M17.5 9.5l-5 5';

/** dialer: the round Phone button that opens the keypad when there is no call (the office portals; not the field app, whose tabs sit there). */
export function VoiceDock({ quiet, dialer }: { quiet?: boolean; dialer?: boolean }) {
  const st = useSyncExternalStore(subscribeVoice, voiceState, () => IDLE);
  const [now, setNow] = useState(() => Date.now());
  // the keypad and the audio choices belong to one call (st.since): the next call starts without them
  const [padFor, setPadFor] = useState<number | null>(null);
  const [audioFor, setAudioFor] = useState<{ at: number; a: AudioDevices } | null>(null);
  const [typed, setTyped] = useState('');
  const [tab, setTab] = useState<'keypad' | 'contacts'>('keypad');
  useEffect(() => { if (!quiet) startVoice(); }, [quiet]);
  useEffect(() => {
    if (st.phase !== 'in_call') return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [st.phase]);
  if (quiet) return null;
  if (st.phase === 'idle') {
    if (!dialer) return null;
    return <button type="button" className="vc-launch" onClick={() => { setTyped(''); setTab('keypad'); openDialer(); }} aria-label="Phone: call a number" title="Call a number" data-testid="voice-launch"><Ic d={PHONE} /></button>;
  }
  const who = st.who ?? 'A caller';
  const pad = st.phase === 'in_call' && padFor === st.since;
  const audio = st.phase === 'in_call' && audioFor && audioFor.at === st.since ? audioFor.a : null;
  const setPad = (on: boolean) => setPadFor(on ? (st.since ?? null) : null);
  const setAudio = (a: AudioDevices | null) => setAudioFor(a && st.since ? { at: st.since, a } : null);
  const number = st.number && st.number !== who ? (st.number.includes('•') ? st.number : prettyNumber(st.number)) : null;
  const dial = () => { const n = e164(typed); if (n) void placeCall({ number: n }); };
  const press = (k: string) => { if (st.phase === 'dialing') setTyped((t) => (t + k).slice(0, 20)); else sendDigit(k); };
  const keypad = (testId: string) => (
    <div className="vc-pad" data-testid={testId}>{KEYS.map(([k, sub]) => <button key={k} type="button" className="vc-key" onClick={() => press(k)} aria-label={k === '*' ? 'Star' : k === '#' ? 'Pound' : k}>
      <span className="vc-key__n">{k}</span><span className="vc-key__s" aria-hidden="true">{sub}</span></button>)}</div>
  );
  const status = st.phase === 'ringing_in' ? 'Incoming call' : st.phase === 'starting' ? 'Starting the call...' : st.phase === 'calling' ? 'Calling from the CarmaCars number...'
    : st.phase === 'in_call' ? (st.held ? 'On hold' : clock(now - (st.since ?? now))) : '';
  return (
    <section className={`vc vc--${st.phase}`} role="dialog" aria-modal="false" aria-label="Phone" data-testid="voice-dock" data-phase={st.phase}>
      {st.phase === 'dialing' && <>
        <div className="vc-head"><button type="button" className="vc-x" onClick={dismiss} aria-label="Close the keypad">×</button></div>
        <div className="vc-tabs" role="tablist" aria-label="Call by">
          {(['keypad', 'contacts'] as const).map((t) => <button key={t} type="button" role="tab" aria-selected={tab === t} className={`vc-tab${tab === t ? ' is-on' : ''}`}
            onClick={() => setTab(t)} data-testid={`voice-tab-${t}`}>{t === 'keypad' ? 'Keypad' : 'Contacts'}</button>)}
        </div>
        {tab === 'contacts' ? <Contacts /> : <form className="vc-dial" onSubmit={(e) => { e.preventDefault(); dial(); }}>
          <label className="vh" htmlFor="vc-number">Number to call</label>
          <input id="vc-number" className="vc-num" type="tel" inputMode="tel" autoComplete="off" autoFocus value={typed} placeholder="Enter a number"
            onChange={(e) => setTyped(e.target.value.replace(/[^0-9+*#()\s.-]/g, '').slice(0, 20))} data-testid="voice-number" />
          <p id="vc-number-hint" className="vc-hint small muted">{typed && !e164(typed) ? 'A Canadian or US number, or + and the country code.' : 'They see the CarmaCars number.'}</p>
          {keypad('voice-keypad')}
          <div className="vc-row">
            <span className="vc-spacer" />
            <button type="submit" className="vc-round vc-round--go" disabled={!e164(typed)} aria-describedby="vc-number-hint" aria-label="Call" data-testid="voice-call"><Ic d={PHONE} /></button>
            {typed ? <button type="button" className="vc-round vc-round--plain" onClick={() => setTyped((t) => t.slice(0, -1))} aria-label="Delete the last digit"><Ic d={BACK} /></button> : <span className="vc-spacer" />}
          </div>
        </form>}
      </>}
      {st.phase !== 'dialing' && st.phase !== 'problem' && <>
        <div className="vc-who">
          <span className="vc-avatar" aria-hidden="true">{initial(who)}</span>
          <p className="vc-name" data-testid="voice-who">{who}</p>
          {number && <p className="vc-number">{number}</p>}
          <p className="vc-status" role="status" data-testid="voice-status">{status}</p>
        </div>
        {st.phase === 'in_call' && (pad ? keypad('voice-dtmf') : <div className="vc-ctrls">
          <Ctl label={st.muted && !st.held ? 'Unmute' : 'Mute'} on={!!st.muted && !st.held} d={st.muted && !st.held ? MIC_OFF : MIC} onClick={toggleMute} disabled={!!st.held} why="Press Resume first" testId="voice-mute" />
          <Ctl label="Keypad" d={PAD} onClick={() => setPad(true)} testId="voice-pad" />
          <Ctl label="Speaker" on={!!audio} d={SPEAKER} onClick={() => setAudio(audio ? null : audioDevices())} testId="voice-audio" />
          <Ctl label={st.held ? 'Resume' : 'Hold'} on={!!st.held} d={HOLD} onClick={toggleHold} testId="voice-hold" />
        </div>)}
        {st.phase === 'in_call' && audio && !pad && <AudioPick a={audio} onChange={() => setAudio(audioDevices())} />}
        <div className="vc-row">
          {st.phase === 'ringing_in' ? <>
            <Round kind="end" label="Decline" onClick={decline} testId="voice-decline" />
            <Round kind="go" label="Answer" onClick={answer} testId="voice-answer" />
          </> : <>
            {pad ? <button type="button" className="vc-link" onClick={() => setPad(false)}>Hide keypad</button> : <span className="vc-spacer" />}
            <Round kind="end" label={st.phase === 'starting' ? 'Cancel' : 'End call'} onClick={hangUp} testId="voice-hangup" />
            <span className="vc-spacer" />
          </>}
        </div>
      </>}
      {st.phase === 'problem' && <>
        <p className="alert alert--warn small" role="alert" data-testid="voice-problem"><span>{st.message ?? 'The call did not go through.'}</span></p>
        <p className="vc-acts"><button type="button" className="btn btn--ghost btn--sm" onClick={dismiss}>Close</button>
          <button type="button" className="btn btn--primary btn--sm" onClick={() => { dismiss(); openDialer(); }}>Keypad</button></p>
      </>}
    </section>
  );
}

/** The contacts tab: the people called last, or a search by name or number; a tap calls (Sales: by the record, masked). */
function Contacts() {
  const [q, setQ] = useState('');
  const [list, setList] = useState<VoiceContact[] | null | undefined>(undefined);
  useEffect(() => {
    let live = true;
    const t = setTimeout(() => { void voiceContacts(q).then((r) => { if (live) setList(r); }); }, q ? 300 : 0);
    return () => { live = false; clearTimeout(t); };
  }, [q]);
  const short = q.trim().length === 1;
  return (
    <div className="vc-contacts" data-testid="voice-contacts">
      <label className="vh" htmlFor="vc-find">Find a person</label>
      <input id="vc-find" className="input vc-find" type="search" autoComplete="off" autoFocus value={q} placeholder="Name or number"
        onChange={(e) => setQ(e.target.value.slice(0, 60))} data-testid="voice-find" />
      <p className="small muted vc-hint">{q.trim() ? (short ? 'Type one more letter or digit.' : 'People found') : 'Called last'}</p>
      {list === undefined ? <p className="small muted" role="status">Loading...</p>
        : list === null ? <p className="alert alert--warn small" role="alert"><span>Contacts did not load. Try again in a moment, or use the keypad.</span></p>
        : list.length === 0 ? <p className="small muted" role="status">{q.trim() ? 'Nobody found.' : 'Nobody called yet.'}</p>
        : <ul className="vc-list">{list.map((c) => (
            <li key={`${c.number}|${c.lead ?? ''}|${c.renter ?? ''}`}>
              <button type="button" className="vc-contact" onClick={() => void placeCall({ number: c.number, name: c.name, lead: c.lead, renter: c.renter })}
                aria-label={`Call ${c.name}`} data-testid="voice-contact">
                <span className="vc-avatar" aria-hidden="true">{initial(c.name)}</span>
                <span className="vc-contact__t"><span className="vc-contact__n">{c.name}</span>{c.shown !== c.name && <span className="vc-contact__s">{c.shown}</span>}</span>
                <span className="vc-contact__go" aria-hidden="true"><Ic d={PHONE} /></span>
              </button>
            </li>))}</ul>}
    </div>
  );
}

function Ctl({ label, d, onClick, on, disabled, why, testId }: { label: string; d: string; onClick: () => void; on?: boolean; disabled?: boolean; why?: string; testId: string }) {
  return (
    <button type="button" className={`vc-ctl${on ? ' is-on' : ''}`} onClick={onClick} aria-pressed={on} disabled={disabled} title={disabled ? why : undefined} data-testid={testId}>
      <span className="vc-ctl__b"><Ic d={d} /></span><span className="vc-ctl__t">{label}</span>
    </button>
  );
}

function Round({ kind, label, onClick, testId }: { kind: 'go' | 'end'; label: string; onClick: () => void; testId: string }) {
  return (
    <span className="vc-roundwrap">
      <button type="button" className={`vc-round vc-round--${kind}`} onClick={onClick} aria-label={label} data-testid={testId}>
        <span className={kind === 'end' ? 'vc-end' : ''}><Ic d={PHONE} /></span>
      </button>
      <span className="vc-ctl__t" aria-hidden="true">{label}</span>
    </span>
  );
}

/** The microphone and (where the browser lets a page choose) the speaker for this call. */
function AudioPick({ a, onChange }: { a: AudioDevices; onChange: () => void }) {
  const [err, setErr] = useState<string | null>(null);
  const pick = async (f: (id: string) => Promise<boolean>, id: string) => { setErr((await f(id)) ? null : 'That device could not be used. Choose another.'); onChange(); };
  return (
    <div className="vc-audio" data-testid="voice-audio-pick">
      {a.outputs.length > 0
        ? <label className="vc-sel small"><span>Speaker</span>
            <select className="input" value={a.output ?? ''} onChange={(e) => void pick(chooseSpeaker, e.target.value)} data-testid="voice-speaker">
              {a.outputs.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select></label>
        : <p className="small muted">This browser plays the call on the device&apos;s own speaker or headset. On a phone, use its volume buttons or connect a headset.</p>}
      {a.inputs.length > 0 && <label className="vc-sel small"><span>Microphone</span>
        <select className="input" value={a.input ?? ''} onChange={(e) => void pick(chooseMicrophone, e.target.value)} data-testid="voice-mic">
          {!a.input && <option value="">Default microphone</option>}
          {a.inputs.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select></label>}
      {err && <p className="alert alert--error small" role="alert"><span>{err}</span></p>}
    </div>
  );
}
