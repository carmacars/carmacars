'use client';
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { acceptSlide, openSession, orderPeople, type MediaSession, type Msg, type Person, type Ticket } from './adapter';
import './calls.css';

// The call page (r50, 5010): the video tiles, microphone, camera and screen share, raise hand, chat and, beside the
// video, the townhall deck in sync with the presenter (anyone may browse on their own and come back), or the candidate's
// details for an interview. The server gives the ticket (who, which room, as what) only when Join is pressed.
export interface DeckSlide { key: string; title: string; points: Array<{ label: string; value: string }>; lines: string[] }
type JoinAs = { room: 'townhall' } | { room: 'interview'; application_id: string };
interface Chat { id: string; from: string; name: string; text: string; at: number }
interface Live { in: Array<{ identity: string; name: string; role: string; since: string }>; left: Array<{ identity: string; name: string; minutes: number }>; not_joined: Array<{ user_id: string; name: string }> }

export function CallRoom({ join, title, slides, side, sideTitle = 'Details', live = false, fallbackUrl, leaveHref }: {
  join: { as?: JoinAs; guest?: boolean }; title: string; slides?: DeckSlide[]; side?: ReactNode; sideTitle?: string; live?: boolean; fallbackUrl?: string | null; leaveHref: string;
}) {
  const [phase, setPhase] = useState<'lobby' | 'joining' | 'in' | 'left'>('lobby');
  const [error, setError] = useState<string | null>(null);
  const [people, setPeople] = useState<Person[]>([]);
  const [me, setMe] = useState<Ticket | null>(null);
  const [mic, setMic] = useState(true);
  const [cam, setCam] = useState(true);
  const [screen, setScreen] = useState(false);
  const [hands, setHands] = useState<Record<string, boolean>>({});
  const [chat, setChat] = useState<Chat[]>([]);
  const [unread, setUnread] = useState(0);
  const [tab, setTab] = useState<'deck' | 'chat' | 'people' | 'side'>(slides?.length ? 'deck' : side ? 'side' : 'chat');
  const [presenterSlide, setPresenterSlide] = useState(0);
  const [mySlide, setMySlide] = useState(0);
  const [follow, setFollow] = useState(true);
  const [liveList, setLiveList] = useState<Live | null>(null);
  const [session, setSession] = useState<MediaSession | null>(null);
  const s = useRef<MediaSession | null>(null);
  const meRole = useRef<Person['role'] | null>(null);
  const mySlideRef = useRef(0);
  const tabRef = useRef(tab);
  useEffect(() => { tabRef.current = tab; }, [tab]);
  useEffect(() => { mySlideRef.current = mySlide; }, [mySlide]);
  const presenting = me?.role === 'presenter';
  const n = slides?.length ?? 0;
  const shown = follow && !presenting ? presenterSlide : mySlide;
  const body = useMemo(() => JSON.stringify(join), [join]);

  const presence = useCallback((event: 'joined' | 'seen' | 'left') => {
    const data = JSON.stringify({ ...JSON.parse(body), event });
    if (event === 'left' && typeof navigator !== 'undefined' && navigator.sendBeacon) { navigator.sendBeacon('/api/calls/presence', new Blob([data], { type: 'application/json' })); return; }
    void fetch('/api/calls/presence', { method: 'POST', headers: { 'content-type': 'application/json' }, body: data, keepalive: true }).catch(() => undefined);
  }, [body]);

  const onMsg = useCallback((from: string, name: string, m: Msg, fromRole: Person['role'] | undefined) => {
    if (m.t === 'slide' && acceptSlide(fromRole, m)) setPresenterSlide(m.i);
    if (m.t === 'ask' && s.current && meRole.current === 'presenter') s.current.send({ t: 'slide', i: mySlideRef.current });
    if (m.t === 'hand') setHands((h) => ({ ...h, [from]: m.up }));
    if (m.t === 'chat') { setChat((c) => (c.some((x) => x.id === m.id) ? c : [...c, { id: m.id, from, name, text: m.text, at: m.at }].slice(-200))); if (tabRef.current !== 'chat') setUnread((u) => u + 1); }
  }, []);

  async function start() {
    setPhase('joining'); setError(null);
    try {
      const r = await fetch('/api/calls/token', { method: 'POST', headers: { 'content-type': 'application/json' }, body });
      const t = (await r.json()) as Ticket & { error?: string };
      if (!r.ok || t.error) throw new Error(t.error ?? 'The call could not be opened');
      if (t.provider === 'off') throw new Error('The call in the site is off right now. Use the outside call link.');
      const sess = await openSession(t);
      s.current = sess; meRole.current = t.role; setMe(t); setSession(sess);
      sess.onChange(() => setPeople(orderPeople(sess.people())));
      sess.onMessage((rcv) => onMsg(rcv.from, rcv.name, rcv.msg, sess.people().find((p) => p.identity === rcv.from)?.role));
      sess.onEnded(() => { setPhase('left'); presence('left'); });
      await sess.connect();
      await sess.setMic(mic).catch(() => setMic(false));
      await sess.setCam(cam).catch(() => setCam(false));
      setPeople(orderPeople(sess.people()));
      setPhase('in');
      presence('joined');
      if (t.role !== 'presenter') sess.send({ t: 'ask' });
      else sess.send({ t: 'slide', i: mySlideRef.current });
    } catch (e) {
      setError((e as Error).message); setPhase('lobby');
    }
  }
  function leave() { s.current?.disconnect(); s.current = null; setSession(null); setPhase('left'); presence('left'); }

  // the heartbeat; the presenter repeats the slide for whoever came in late; leaving the page leaves the call
  useEffect(() => {
    if (phase !== 'in') return;
    const hb = setInterval(() => presence('seen'), 30_000);
    const rep = setInterval(() => { if (meRole.current === 'presenter') s.current?.send({ t: 'slide', i: mySlideRef.current }); }, 8_000);
    const bye = () => presence('left');
    window.addEventListener('pagehide', bye);
    return () => { clearInterval(hb); clearInterval(rep); window.removeEventListener('pagehide', bye); };
  }, [phase, presence]);
  useEffect(() => () => s.current?.disconnect(), []);

  // Admin: who is in now, who left, who has not joined
  useEffect(() => {
    if (!live || phase !== 'in' || !me) return;
    let stop = false;
    const load = () => fetch(`/api/calls/live?room=${encodeURIComponent(me.room)}`).then((r) => r.json()).then((v: Live) => { if (!stop && Array.isArray(v.in)) setLiveList(v); }).catch(() => undefined);
    void load();
    const i = setInterval(load, 10_000);
    return () => { stop = true; clearInterval(i); };
  }, [live, phase, me]);

  function go(i: number) {
    const j = Math.max(0, Math.min(n - 1, i));
    setMySlide(j);
    if (presenting) { setPresenterSlide(j); s.current?.send({ t: 'slide', i: j }); } else setFollow(false);
  }
  async function toggle(kind: 'mic' | 'cam' | 'screen') {
    const sess = s.current; if (!sess) return;
    try {
      if (kind === 'mic') { await sess.setMic(!mic); setMic(!mic); }
      if (kind === 'cam') { await sess.setCam(!cam); setCam(!cam); }
      if (kind === 'screen') { await sess.setScreen(!screen); setScreen(!screen); }
    } catch (e) { setError(kind === 'screen' ? 'Screen sharing was not allowed.' : `The ${kind === 'mic' ? 'microphone' : 'camera'} is not available: ${(e as Error).message}`); }
  }
  function hand() { const up = !hands[me?.identity ?? '']; setHands((h) => ({ ...h, [me!.identity]: up })); s.current?.send({ t: 'hand', up }); }
  function say(text: string) {
    const v = text.trim().slice(0, 500); if (!v || !me) return;
    const m: Chat = { id: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`, from: me.identity, name: me.name, text: v, at: Date.now() };
    setChat((c) => [...c, m]); s.current?.send({ t: 'chat', id: m.id, text: m.text, at: m.at });
  }

  if (phase === 'left') {
    return (<div className="call-end pt-card ad-card stack" data-testid="call-left"><h2 className="d3">You left the call</h2>
      <div className="row"><button type="button" className="btn btn--primary btn--sm" onClick={() => setPhase('lobby')} data-testid="call-rejoin">Join again</button>
        <a className="btn btn--ghost btn--sm" href={leaveHref}>Back</a></div></div>);
  }
  if (phase !== 'in') {
    return (<div className="call-lobby pt-card ad-card stack" data-testid="call-lobby">
      <h2 className="d3">{title}</h2>
      <p className="small">Your camera and microphone open when you join. You can turn either off at any time.</p>
      <div className="call-lobby__opts">
        <label className="call-check"><input type="checkbox" checked={mic} onChange={(e) => setMic(e.target.checked)} data-testid="call-lobby-mic" /> <span>Microphone on</span></label>
        <label className="call-check"><input type="checkbox" checked={cam} onChange={(e) => setCam(e.target.checked)} data-testid="call-lobby-cam" /> <span>Camera on</span></label>
      </div>
      {error && <p className="alert alert--error" role="alert" data-testid="call-error"><span>{error}</span></p>}
      <div className="row">
        <button type="button" className="btn btn--primary" onClick={() => void start()} disabled={phase === 'joining'} aria-busy={phase === 'joining'} title={phase === 'joining' ? 'Joining the call' : undefined} data-testid="call-join" data-guide="call-join">{phase === 'joining' ? 'Joining...' : 'Join the call'}</button>
        {fallbackUrl && <a className="btn btn--ghost btn--sm" href={fallbackUrl} target="_blank" rel="noopener noreferrer" data-testid="call-fallback">Use the outside call link</a>}
      </div>
      {!!n && <details className="call-lobby__deck" open={!!error} data-testid="call-lobby-deck"><summary className="link small">Read the slides without the call</summary><DeckList slides={slides!} testId="call-lobby-deck-list" /></details>}
    </div>);
  }

  const slide = slides?.[shown];
  const raised = people.filter((p) => hands[p.identity]);
  return (
    <div className="call" data-testid="call-room" data-provider={me?.provider}>
      <section className="call-stage" aria-label="Video">
        <ul className={`call-tiles call-tiles--${Math.min(people.length, 4)}`} data-testid="call-tiles">
          {people.map((p) => <Tile key={p.identity} p={p} session={session} hand={!!hands[p.identity]} />)}
        </ul>
        {error && <p className="alert alert--warn small" role="status"><span>{error}</span></p>}
        <div className="call-bar" role="toolbar" aria-label="Call controls" data-guide="call-controls">
          <button type="button" className={`btn btn--sm ${mic ? 'btn--ghost' : 'btn--primary'}`} aria-pressed={!mic} onClick={() => void toggle('mic')} data-testid="call-mic">{mic ? 'Mute' : 'Unmute'}</button>
          <button type="button" className={`btn btn--sm ${cam ? 'btn--ghost' : 'btn--primary'}`} aria-pressed={!cam} onClick={() => void toggle('cam')} data-testid="call-cam">{cam ? 'Camera off' : 'Camera on'}</button>
          <button type="button" className="btn btn--sm btn--ghost call-bar__share" aria-pressed={screen} onClick={() => void toggle('screen')} data-testid="call-screen">{screen ? 'Stop sharing' : 'Share screen'}</button>
          <button type="button" className="btn btn--sm btn--ghost" aria-pressed={!!hands[me?.identity ?? '']} onClick={hand} data-testid="call-hand" data-guide="call-hand">{hands[me?.identity ?? ''] ? 'Lower hand' : 'Raise hand'}</button>
          <button type="button" className="btn btn--sm btn--danger" onClick={leave} data-testid="call-leave">Leave</button>
        </div>
      </section>
      <aside className="call-side" aria-label="Beside the call">
        <div className="call-tabs" role="tablist">
          {!!n && <button type="button" role="tab" aria-selected={tab === 'deck'} onClick={() => setTab('deck')} data-testid="call-tab-deck">Slides</button>}
          {side && <button type="button" role="tab" aria-selected={tab === 'side'} onClick={() => setTab('side')} data-testid="call-tab-side">{sideTitle}</button>}
          <button type="button" role="tab" aria-selected={tab === 'chat'} onClick={() => { setTab('chat'); setUnread(0); }} data-testid="call-tab-chat">Chat{unread ? ` (${unread})` : ''}</button>
          <button type="button" role="tab" aria-selected={tab === 'people'} onClick={() => setTab('people')} data-testid="call-tab-people">People ({people.length}){raised.length ? `, ${raised.length} hand${raised.length > 1 ? 's' : ''}` : ''}</button>
        </div>
        {tab === 'deck' && slide && <div className="call-deck" data-testid="call-deck" data-slide={shown} data-guide="call-deck">
          <p className="small muted">Slide {shown + 1} of {n}{presenting ? ': everyone sees this one' : follow ? ': following the presenter' : ''}</p>
          <h3 className="d4" data-testid="call-slide-title">{slide.title}</h3>
          {!!slide.points.length && <dl className="th-points">{slide.points.map((p) => <div key={p.label}><dt className="small muted">{p.label}</dt><dd>{p.value}</dd></div>)}</dl>}
          {!!slide.lines.length && <ul className="small">{slide.lines.map((l) => <li key={l}>{l}</li>)}</ul>}
          <div className="call-deck__nav">
            <button type="button" className="btn btn--sm btn--ghost" onClick={() => go(shown - 1)} disabled={shown === 0} title={shown === 0 ? 'This is the first slide' : undefined} data-testid="call-slide-prev">Previous</button>
            <button type="button" className={`btn btn--sm ${presenting ? 'btn--primary' : 'btn--ghost'}`} onClick={() => go(shown + 1)} disabled={shown >= n - 1} title={shown >= n - 1 ? 'This is the last slide' : undefined} data-testid="call-slide-next">Next</button>
            {!presenting && !follow && <button type="button" className="btn btn--sm btn--ghost" onClick={() => setFollow(true)} data-testid="call-slide-follow">Back to the presenter</button>}
          </div>
        </div>}
        {tab === 'side' && <div className="call-panel">{side}</div>}
        {tab === 'chat' && <div className="call-chat" data-testid="call-chat">
          <ol className="call-chat__list" aria-live="polite">{chat.map((c) => <li key={c.id} className={c.from === me?.identity ? 'is-me' : undefined}><b>{c.from === me?.identity ? 'You' : c.name}</b> <span>{c.text}</span></li>)}</ol>
          {!chat.length && <p className="small muted">Messages here go to everyone in the call and are not kept after it.</p>}
          <form className="call-chat__form" onSubmit={(e) => { e.preventDefault(); const f = e.currentTarget; const i = f.elements.namedItem('msg') as HTMLInputElement; say(i.value); i.value = ''; }}>
            <label className="vh" htmlFor="call-msg">Message</label>
            <input id="call-msg" name="msg" maxLength={500} autoComplete="off" placeholder="Write to everyone" data-testid="call-chat-input" />
            <button type="submit" className="btn btn--sm btn--primary" data-testid="call-chat-send">Send</button>
          </form>
        </div>}
        {tab === 'people' && <div className="call-panel" data-testid="call-people">
          <ul className="call-people">{people.map((p) => <li key={p.identity}><span>{p.local ? `${p.name} (you)` : p.name}</span>
            <span className="small muted">{p.role === 'presenter' ? 'Presenter' : p.role === 'host' ? 'Interviewer' : p.role === 'guest' ? 'Candidate' : ''}{hands[p.identity] ? ' · hand raised' : ''}{p.mic ? '' : ' · muted'}</span></li>)}</ul>
          {live && liveList && <div className="stack" data-testid="call-live">
            <p className="small"><b>In the call now ({liveList.in.length})</b>: recorded as there by itself.</p>
            {liveList.left.length > 0 && <p className="small"><b>Left</b>: {liveList.left.map((x) => `${x.name} (${x.minutes} min)`).join(', ')}</p>}
            {liveList.not_joined.length > 0 && <p className="small" data-testid="call-not-joined"><b>Not joined yet ({liveList.not_joined.length})</b>: {liveList.not_joined.map((x) => x.name).join(', ')}</p>}
          </div>}
        </div>}
      </aside>
    </div>
  );
}

/** Every slide, in order, with no call: the deck stays readable when the call cannot be joined (the media server is down or
 *  off, the camera is refused, an outside link is in use). R50 hotfix 2: during the townhall nobody could see the deck. */
export function DeckList({ slides, testId = 'call-deck-list' }: { slides: DeckSlide[]; testId?: string }) {
  return (<ol className="stack" data-testid={testId}>{slides.map((x, i) => (
    <li key={x.key} className="pt-card ad-card stack" data-testid={`${testId}-slide-${i}`}>
      <h3 className="d4">{i + 1}. {x.title}</h3>
      {!!x.points.length && <dl className="th-points">{x.points.map((p) => <div key={p.label}><dt className="small muted">{p.label}</dt><dd>{p.value}</dd></div>)}</dl>}
      {!!x.lines.length && <ul className="small">{x.lines.map((l) => <li key={l}>{l}</li>)}</ul>}
    </li>))}</ol>);
}

function Tile({ p, session, hand }: { p: Person; session: MediaSession | null; hand: boolean }) {
  const v = useRef<HTMLVideoElement>(null);
  const [has, setHas] = useState(false);
  const src: 'screen' | 'camera' = p.screen ? 'screen' : 'camera';
  useEffect(() => { setHas(!!(v.current && session && (p.cam || p.screen) && session.attach(p.identity, src, v.current))); }, [session, p.identity, p.cam, p.screen, src]);
  const initials = p.name.split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase();
  return (
    <li className={`call-tile${p.speaking ? ' is-speaking' : ''}${p.screen ? ' is-screen' : ''}`} data-testid={`call-tile-${p.local ? 'me' : p.identity}`}>
      <video ref={v} autoPlay playsInline muted={p.local} hidden={!has} />
      {!has && <span className="call-tile__face" aria-hidden="true">{initials}</span>}
      <span className="call-tile__name">{p.local ? 'You' : p.name}{p.mic ? '' : ' (muted)'}{hand ? ' (hand up)' : ''}</span>
    </li>
  );
}
