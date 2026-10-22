'use client';
import './chat.css';
import { useCallback, useEffect, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';
import { browserRpc } from '@/lib/browser-rpc';
import { onBeaconReply, pageContext, sessionId, setChatOpen, visitorId, type BeaconReply } from './beacon';
import { SavedAsYouType, useCapture } from '@/features/capture/useCapture';
import { greetingAllowed, greetingWait } from './greeting';

// Live chat (migration 0060), the visitor's side: a button in the corner, loaded after the page. The CarmaCars
// assistant answers first; "Talk to a person" (or anything it should not answer) brings a staff member, who can also
// start a chat from the Live visitors page. New messages are read straight from the database every few seconds
// while the chat is open (public.chat_poll, by the conversation's secret); sending goes through /api/chat.
type Msg = { id: number; at: string; sender: 'visitor' | 'ai' | 'staff' | 'system'; body: string; name?: string | null; pending?: boolean };
type Conv = { token: string; number: string; status: 'ai' | 'waiting' | 'human' | 'closed'; offline?: boolean; has_contact?: boolean; agent?: string | null };
type Poll = { ok: boolean; error?: string; number: string; status: Conv['status']; offline: boolean; staff_typing: boolean; has_contact: boolean; agent: string | null; messages: Msg[] };
const KEY = 'cc_chat';
const store = { get: () => { try { return localStorage.getItem(KEY); } catch { return null; } }, set: (t: string | null) => { try { if (t) localStorage.setItem(KEY, t); else localStorage.removeItem(KEY); } catch { /* private mode */ } } };
const time = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' });
const device = () => (matchMedia('(max-width: 599px)').matches ? 'phone' : matchMedia('(max-width: 1024px)').matches ? 'tablet' : 'desktop');

// The greeting (0100): after chat_greeting_seconds on the site (45 by default, counted from the visit's first page in
// this tab), a small preview on the chat button with a first message from CarmaCars, for the page it opens on (the car
// on a car page, the service on a service page). Once a visit, never over a discount game (it waits for the game to
// close; the games' watcher marks <html data-cc-game> and sends cc:game), never in the portals, booking or payment
// pages (the database answers no greeting there). Automated browsers get it only when a test asks (cc_chat_greet_e2e).
const GREET = 'cc_chat_greet';
type GreetVisit = { start: number; done?: boolean; after?: number };
const greetVisit = (): GreetVisit => {
  try {
    const g = JSON.parse(sessionStorage.getItem(GREET) ?? 'null') as GreetVisit | null;
    if (g && typeof g.start === 'number') return g;
    const n = { start: Date.now() };
    sessionStorage.setItem(GREET, JSON.stringify(n));
    return n;
  } catch { return { start: Date.now() }; }
};
const greetSave = (g: Partial<GreetVisit>) => { try { sessionStorage.setItem(GREET, JSON.stringify({ ...greetVisit(), ...g })); } catch { /* private mode */ } };
const greetDone = () => greetSave({ done: true });
type Greeting = { after: number; text: string | null };
const greetAutomated = () => { try { return navigator.webdriver && localStorage.getItem('cc_chat_greet_e2e') !== '1'; } catch { return navigator.webdriver; } };
/** A test may shorten the wait in an automated browser (cc_chat_greet_e2e_after, seconds); a person's browser never reads it. */
const greetAfter = (s: number) => { try { const v = navigator.webdriver ? Number(localStorage.getItem('cc_chat_greet_e2e_after')) : NaN; return v > 0 ? v : s; } catch { return s; } };
const gameOnScreen = () => document.documentElement.hasAttribute('data-cc-game');

async function post<T>(body: Record<string, unknown>): Promise<T> {
  const r = await fetch('/api/chat', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), credentials: 'same-origin' });
  return (await r.json()) as T;
}

export function ChatWidget() {
  const path = usePathname();
  const [open, setOpen] = useState(false);
  // a conversation already going in this browser (the widget only renders in the browser)
  const [conv, setConv] = useState<Conv | null>(() => { const t = store.get(); return t && /^[0-9a-f]{64}$/.test(t) ? { token: t, number: '', status: 'ai' } : null; });
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [typing, setTyping] = useState(false);
  const [unread, setUnread] = useState(0);
  const [cfg, setCfg] = useState<NonNullable<BeaconReply['cfg']>>({ chat: true, greet_after: 0, greet_text: '' });
  const [bubble, setBubble] = useState<{ kind: 'greeting' | 'invite'; text: string; from?: string; token?: string; page?: string } | null>(null);
  // a discount game is on screen: the greeting stays hidden until it closes (0100)
  const [gameOpen, setGameOpen] = useState(false);
  const [error, setError] = useState('');
  const [banner, setBanner] = useState(true);
  const lastId = useRef(0);
  const lastTyping = useRef(0);
  const input = useRef<HTMLTextAreaElement>(null);
  const log = useRef<HTMLDivElement>(null);
  const launcher = useRef<HTMLButtonElement>(null);
  const openRef = useRef(open);
  useEffect(() => { openRef.current = open; }, [open]);

  const merge = useCallback((p: Poll) => {
    if (!p.ok) { if (p.error === 'not_found') { store.set(null); setConv(null); setMsgs([]); lastId.current = 0; } return; }
    setConv((c) => (c ? { ...c, number: p.number, status: p.status, offline: p.offline, has_contact: p.has_contact, agent: p.agent } : c));
    setTyping(Boolean(p.staff_typing));
    if (p.messages?.length) {
      const fresh = p.messages.filter((m) => m.id > lastId.current);
      if (fresh.length) {
        lastId.current = Math.max(lastId.current, ...fresh.map((m) => m.id));
        setMsgs((old) => [...old.filter((m) => !m.pending), ...fresh]);
        if (!openRef.current) setUnread((u) => u + fresh.filter((m) => m.sender !== 'visitor').length);
      }
    }
    if (p.status === 'closed') store.set(null);
  }, []);

  const poll = useCallback(async (token: string) => {
    try { merge(await browserRpc<Poll>('chat_poll', { p_token: token, p_after: lastId.current })); } catch { /* next tick */ }
  }, [merge]);

  const restored = useRef(conv?.token);
  useEffect(() => { if (restored.current) void poll(restored.current); }, [poll]);

  // the beacon's answer: the chat's settings, and a chat a staff member started
  useEffect(() => onBeaconReply((r) => {
    if (r.cfg) setCfg(r.cfg);
    if (r.invite && r.invite.token !== store.get()) setBubble({ kind: 'invite', text: r.invite.message, from: r.invite.from, token: r.invite.token });
  }), []);

  // the cookie banner sits in the same corner on a phone: the button waits for it
  useEffect(() => {
    const check = () => setBanner(Boolean(document.querySelector('section.cookie')));
    check();
    const t = setInterval(check, 1000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    const f = () => setGameOpen(gameOnScreen());
    f();
    addEventListener('cc:game', f);
    return () => removeEventListener('cc:game', f);
  }, []);

  // the greeting (0100), once a visit, for the page it opens on. When it opens comes from the database (asked once a
  // visit, or from the beacon's reply when there is one); its words are asked for the page it opens on.
  useEffect(() => {
    if (!cfg.chat || conv || open || !greetingAllowed(path ?? '/') || greetAutomated()) return;
    const g = greetVisit();
    if (g.done) return;
    const page = path ?? '/';
    let live = true;
    let t: ReturnType<typeof setTimeout> | undefined;
    const plan = (after: number) => {
      const wait = greetingWait({ after: greetAfter(after), start: g.start, now: Date.now(), done: g.done });
      if (wait === null) return;
      t = setTimeout(() => {
        void browserRpc<Greeting>('chat_greeting', { p_page: page }).then((r) => {
          if (!live || !r?.text) return;
          greetDone();
          setBubble((b) => b ?? { kind: 'greeting', text: r.text!, page });
        }).catch(() => undefined);
      }, wait);
    };
    const known = cfg.greet_after > 0 ? cfg.greet_after : g.after;
    if (typeof known === 'number') plan(known);
    else void browserRpc<Greeting>('chat_greeting', { p_page: page }).then((r) => { if (!live || !r) return; greetSave({ after: r.after }); plan(r.after); }).catch(() => undefined);
    return () => { live = false; if (t) clearTimeout(t); };
  }, [cfg, conv, open, path]);

  // new messages: every 3 seconds while open, every 15 while folded away
  useEffect(() => {
    if (!conv || conv.status === 'closed') return;
    const every = open ? 3000 : 15000;
    const t = setInterval(() => { if (document.visibilityState === 'visible') void poll(conv.token); }, every);
    return () => clearInterval(t);
  }, [conv, open, poll]);

  useEffect(() => { setChatOpen(Boolean(conv && conv.status !== 'closed')); }, [conv]);
  useEffect(() => { if (open) requestAnimationFrame(() => input.current?.focus()); }, [open]);
  useEffect(() => { log.current?.scrollTo({ top: log.current.scrollHeight }); }, [msgs, typing, open]);

  const start = async (opts: { greeting?: boolean; greetingPage?: string; token?: string } = {}) => {
    setError('');
    const ctx = pageContext(path);
    const r = await post<{ ok: boolean; error?: string; token: string; number: string; status: Conv['status']; has_contact: boolean; on_shift: boolean; messages: Msg[] }>({
      action: 'open', vid: visitorId(), sid: sessionId(), page: path, slug: ctx.slug, greeting: opts.greeting, greeting_page: opts.greetingPage, token: opts.token ?? conv?.token, device: device() });
    if (!r.ok) { setError(r.error === 'limited' ? 'Too many chats from this browser. Try again later or call us.' : 'The chat is not available right now. Call or email us.'); return null; }
    store.set(r.token);
    const c: Conv = { token: r.token, number: r.number, status: r.status, has_contact: r.has_contact };
    setConv(c);
    lastId.current = 0;
    setMsgs([]);
    merge({ ok: true, number: r.number, status: r.status, offline: false, staff_typing: false, has_contact: r.has_contact, agent: null, messages: r.messages });
    return c;
  };

  const openChat = async (from?: 'greeting' | 'invite') => {
    setOpen(true);
    setUnread(0);
    const b = bubble;
    setBubble(null);
    if (from === 'invite' && b?.token) { await start({ token: b.token }); return; }
    if (!conv || conv.status === 'closed') await start({ greeting: from === 'greeting', greetingPage: from === 'greeting' ? b?.page : undefined });
  };

  const send = async (e?: React.FormEvent) => {
    e?.preventDefault();
    const body = text.trim();
    if (!body || busy) return;
    setBusy(true); setError('');
    const c = conv && conv.status !== 'closed' ? conv : await start();
    if (!c) { setBusy(false); return; }
    setText('');
    setMsgs((m) => [...m, { id: -Date.now(), at: new Date().toISOString(), sender: 'visitor', body, pending: true }]);
    try {
      const r = await post<Poll>({ action: 'send', token: c.token, body, after: lastId.current });
      if (!r.ok && r.error === 'limited') setError('You are sending messages very fast. Wait a moment.');
      merge(r);
    } catch { setError('Your message did not go. Check your connection and try again.'); }
    setBusy(false);
  };

  const person = async () => {
    if (!conv) return;
    setBusy(true);
    try { merge(await post<Poll>({ action: 'person', token: conv.token, after: lastId.current })); } catch { /* the poll catches up */ }
    setBusy(false);
  };

  const end = async () => {
    if (!conv) return;
    await post({ action: 'end', token: conv.token }).catch(() => undefined);
    await poll(conv.token);
    store.set(null);
  };

  const onType = (v: string) => {
    setText(v);
    if (conv && conv.status !== 'closed' && Date.now() - lastTyping.current > 4000) {
      lastTyping.current = Date.now();
      void browserRpc('chat_typing', { p_token: conv.token }).catch(() => undefined);
    }
  };

  if (!cfg.chat && !conv) return null;
  const status = !conv ? 'Our assistant answers right away. Ask for a person any time.'
    : conv.status === 'human' ? `${conv.agent ?? 'A team member'} from CarmaCars is here`
    : conv.status === 'waiting' ? (conv.offline ? 'Our team is away. Leave your details below.' : 'A person will reply shortly')
    : conv.status === 'closed' ? 'This chat has ended' : 'The CarmaCars assistant. Ask for a person any time.';
  const needContact = conv && conv.status === 'waiting' && conv.offline && !conv.has_contact;

  return (
    <div className="ccw" data-testid="chat-widget">
      {bubble && !open && !(bubble.kind === 'greeting' && gameOpen) && (
        <div className="ccw-bubble" role="status" data-testid="chat-bubble" data-kind={bubble.kind}>
          <p>{bubble.kind === 'invite' && bubble.from ? <b>{bubble.from} from CarmaCars: </b> : bubble.kind === 'greeting' ? <b className="ccw-bubble__from">CarmaCars</b> : null}{bubble.text}</p>
          <div className="ccw-bubble__btns">
            <button type="button" className="btn btn--primary btn--sm" onClick={() => void openChat(bubble.kind)}>Reply</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setBubble(null)}>No thanks</button>
          </div>
        </div>
      )}
      {open && (
        <section className="ccw-panel" role="dialog" aria-modal="false" aria-labelledby="ccw-title" id="ccw-panel"
          onKeyDown={(e) => { if (e.key === 'Escape') { setOpen(false); launcher.current?.focus(); } }}>
          <header className="ccw-head">
            <div><h2 id="ccw-title" className="ccw-title">Chat with CarmaCars</h2><p className="ccw-status" data-testid="chat-status">{status}</p></div>
            <button type="button" className="ccw-x" aria-label="Close the chat window" onClick={() => { setOpen(false); launcher.current?.focus(); }}>×</button>
          </header>
          <div className="ccw-log" ref={log} role="log" aria-live="polite" aria-label="Messages" tabIndex={0} data-testid="chat-log">
            {!msgs.length && <p className="ccw-sys">Hi! Ask about a car, your dates, prices or how booking works.</p>}
            {msgs.map((m) => m.sender === 'system'
              ? <p key={m.id} className="ccw-sys">{m.body}</p>
              : (
                <div key={m.id} className={`ccw-msg ccw-msg--${m.sender === 'visitor' ? 'me' : 'them'}`} data-sender={m.sender}>
                  {m.sender !== 'visitor' && <span className="ccw-name">{m.name ?? 'CarmaCars'}</span>}
                  <p className="ccw-text">{m.body}</p>
                  <span className="ccw-time">{m.pending ? 'Sending' : time(m.at)}</span>
                </div>))}
            {typing && <p className="ccw-sys" data-testid="chat-typing">{conv?.agent ?? 'CarmaCars'} is typing</p>}
          </div>
          {needContact && <ContactForm token={conv!.token} onDone={() => { void poll(conv!.token); }} />}
          {error && <p className="ccw-error" role="alert">{error}</p>}
          {conv?.status === 'closed' ? (
            <div className="ccw-foot"><button type="button" className="btn btn--primary btn--sm" onClick={() => void start()}>Start a new chat</button></div>
          ) : (
            <form className="ccw-form" onSubmit={send}>
              <label className="vh" htmlFor="ccw-input">Your message</label>
              <textarea id="ccw-input" ref={input} className="ccw-input" rows={2} maxLength={2000} value={text} placeholder="Write a message"
                onChange={(e) => onType(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(); } }} />
              <button type="submit" className="btn btn--primary btn--sm ccw-send" disabled={busy || !text.trim()}>Send</button>
            </form>
          )}
          {conv && conv.status !== 'closed' && (
            <div className="ccw-actions">
              {conv.status === 'ai' && <button type="button" className="ccw-link" onClick={() => void person()} disabled={busy}>Talk to a person</button>}
              <button type="button" className="ccw-link" onClick={() => void end()}>End chat</button>
            </div>
          )}
        </section>
      )}
      {!(banner && !conv && !bubble) && (
        <button type="button" ref={launcher} className="ccw-launch" aria-label={open ? "Close chat" : "Open chat"} aria-expanded={open} aria-controls="ccw-panel" data-testid="chat-open"
          onClick={() => (open ? setOpen(false) : void openChat())}>
          <svg aria-hidden="true" viewBox="0 0 24 24" width="22" height="22"><path fill="currentColor" d="M4 4h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-5 4v-4H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z" /></svg>
          <span>{open ? 'Close chat' : 'Chat'}</span>
          {unread > 0 && !open && <span className="ccw-badge" aria-label={`${unread} new`}>{unread}</span>}
        </button>
      )}
    </div>
  );
}

function ContactForm({ token, onDone }: { token: string; onDone: () => void }) {
  const [v, setV] = useState({ name: '', email: '', phone: '', transcript: true });
  // contact capture (0090): the name, email and phone are saved as each becomes valid, as in every other form
  const cap = useCapture('chat');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <form className="ccw-contact" data-testid="chat-contact" onBlur={() => cap.capture({ name: v.name, email: v.email, phone: v.phone })} onSubmit={async (e) => {
      e.preventDefault();
      cap.cancel();
      if (!v.email.trim() && !v.phone.trim()) { setErr('Give an email or a phone number.'); return; }
      setBusy(true); setErr('');
      const r = await post<{ ok: boolean; error?: string }>({ action: 'contact', token, ...v }).catch(() => ({ ok: false, error: 'Try again.' }));
      setBusy(false);
      if (!r.ok) setErr(r.error ?? 'Try again.'); else onDone();
    }}>
      <p className="ccw-contact__t">Leave your details and we will get back to you.</p>
      <label className="ccw-field"><span>Name</span><input className="input" autoComplete="name" value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} /></label>
      <label className="ccw-field"><span>Email</span><input className="input" type="email" autoComplete="email" value={v.email} onChange={(e) => setV({ ...v, email: e.target.value })} /></label>
      <label className="ccw-field"><span>Phone</span><input className="input" type="tel" autoComplete="tel" value={v.phone} onChange={(e) => setV({ ...v, phone: e.target.value })} /></label>
      <label className="check"><input type="checkbox" checked={v.transcript} onChange={(e) => setV({ ...v, transcript: e.target.checked })} /><span>Email me a copy of this chat</span></label>
      {err && <p className="ccw-error" role="alert">{err}</p>}
      <button type="submit" className="btn btn--primary btn--sm" disabled={busy}>Send my details</button>
      <SavedAsYouType />
    </form>
  );
}
