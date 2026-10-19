'use client';
import './live.css';
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
import { agoWords, clock, EVENT_WORDS, liveDo, liveRead, STATUS_WORDS, type ChatMsg, type Inbox, type Thread } from './staff';

// Admin > Bookings > Live chat and the assistants' Live chat (migration 0060): every conversation, the assistant's or a
// person's, with the visitor's visit beside it. Take over (the assistant stops), reply, hand back, close; typing and
// unread counts; a waiting chat shows its minutes against the first reply target. The list refreshes every 5 seconds
// and the open chat every 2.
export function ChatInbox({ initial, portal, openId }: { initial: Inbox; portal: 'admin' | 'va'; openId?: string }) {
  const [inbox, setInbox] = useState(initial);
  const [sel, setSel] = useState<string | null>(openId ?? initial.open.find((c) => c.status === 'waiting')?.id ?? initial.open[0]?.id ?? null);
  const [showClosed, setShowClosed] = useState(false);
  const [err, setErr] = useState('');
  const seenWaiting = useRef(new Set(initial.open.filter((c) => c.status === 'waiting').map((c) => c.id)));

  const refresh = useCallback(async () => {
    try {
      const n = await liveRead<Inbox>('chat_inbox');
      setInbox(n); setErr('');
      // a desktop alert for a chat that starts waiting (Notify me, this browser)
      for (const c of n.open.filter((x) => x.status === 'waiting')) {
        if (!seenWaiting.current.has(c.id)) {
          seenWaiting.current.add(c.id);
          if (n.prefs.desktop_alerts && typeof Notification !== 'undefined' && Notification.permission === 'granted') {
            try { new Notification(`Live chat ${c.number} waits for you`, { body: `${c.who}: ${c.human_reason ?? 'asked for a person'}`, tag: c.id }); } catch { /* not allowed here */ }
          }
        }
      }
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, []);
  useEffect(() => {
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, 5000);
    return () => clearInterval(t);
  }, [refresh]);
  useEffect(() => { document.title = inbox.waiting ? `(${inbox.waiting}) Live chat | CarmaCars` : 'Live chat | CarmaCars'; }, [inbox.waiting]);

  const list = showClosed ? inbox.closed : inbox.open;
  return (
    <div className="lc" data-testid="chat-inbox">
      <div className="lc-top">
        <p className="small">{inbox.waiting ? <b className="lc-wait">{inbox.waiting} waiting for a person</b> : 'Nobody is waiting.'} <span className="muted">{inbox.on_shift} on shift.</span>
          {' '}<span className="muted">Assistant today: {Math.round(inbox.budget.chat_neurons)} of {inbox.budget.chat_cap} neurons{inbox.budget.ok ? '' : ' (off: chats wait for a person)'}.</span></p>
        <Prefs prefs={inbox.prefs} onSaved={refresh} />
      </div>
      {err && <p className="pt-note" role="alert">{err}</p>}
      <div className="lc-grid">
        <nav className="lc-list" aria-label="Conversations">
          <div className="ad-chip-row" role="group" aria-label="Which chats">
            <button type="button" className={`btn btn--sm ${!showClosed ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={!showClosed} onClick={() => setShowClosed(false)}>Open ({inbox.open.length})</button>
            <button type="button" className={`btn btn--sm ${showClosed ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={showClosed} onClick={() => setShowClosed(true)}>Closed</button>
          </div>
          {!list.length ? <p className="small muted">{showClosed ? 'No chat closed in the last 7 days.' : 'No open chat. New chats appear here as visitors start them.'}</p> : (
            <ul>{list.map((c) => (
              <li key={c.id}>
                <button type="button" className={`lc-item${sel === c.id ? ' is-on' : ''}`} aria-current={sel === c.id ? 'true' : undefined} onClick={() => setSel(c.id)} data-testid="chat-item">
                  <span className="lc-item__top"><b>{c.who}</b>{c.unread > 0 && <span className="lc-unread" aria-label={`${c.unread} unread`}>{c.unread}</span>}</span>
                  <span className="lc-item__meta"><span className={`ad-b ${c.status === 'waiting' ? 'ad-b--red' : c.status === 'human' ? 'ad-b--dark' : c.status === 'ai' ? 'ad-b--wait' : 'ad-b--light'}`}>{STATUS_WORDS[c.status]}</span>
                    {c.status === 'waiting' && c.waiting_minutes !== null && <span className={`small ${c.waiting_minutes >= c.target_minutes ? 'lc-late' : 'muted'}`}>{c.waiting_minutes} min (target {c.target_minutes})</span>}
                    {c.assigned_name && <span className="small muted">{c.assigned_name}</span>}</span>
                  <span className="small muted lc-item__last">{c.visitor_typing ? 'typing' : c.last ?? ''}</span>
                  <span className="small muted">{c.number} · {agoWords(c.last_message_at)}{c.online ? ' · on the site' : ''}</span>
                </button>
              </li>))}</ul>)}
        </nav>
        {sel ? <ChatThread key={sel} id={sel} portal={portal} onChange={refresh} /> : <div className="lc-empty small muted">Choose a conversation.</div>}
      </div>
    </div>
  );
}

function Prefs({ prefs, onSaved }: { prefs: Inbox['prefs']; onSaved: () => void }) {
  const save = async (p: Partial<Inbox['prefs']>) => {
    const next = { ...prefs, ...p };
    if (p.desktop_alerts && typeof Notification !== 'undefined' && Notification.permission === 'default') await Notification.requestPermission().catch(() => undefined);
    await liveDo('chat_prefs', next).catch(() => undefined);
    onSaved();
  };
  return (
    <fieldset className="lc-prefs"><legend className="small">Notify me</legend>
      <label className="check small"><input type="checkbox" checked={prefs.email_when_waiting} onChange={(e) => void save({ email_when_waiting: e.target.checked })} /><span>Email me when a chat waits (while I am on shift)</span></label>
      <label className="check small"><input type="checkbox" checked={prefs.desktop_alerts} onChange={(e) => void save({ desktop_alerts: e.target.checked })} /><span>Desktop alerts in this browser</span></label>
    </fieldset>
  );
}

function ChatThread({ id, portal, onChange }: { id: string; portal: 'admin' | 'va'; onChange: () => void }) {
  const [t, setT] = useState<Thread | null>(null);
  const [msgs, setMsgs] = useState<ChatMsg[]>([]);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState('');
  const last = useRef(0);
  const typed = useRef(0);
  const log = useRef<HTMLDivElement>(null);
  const load = useCallback(async () => {
    try {
      const n = await liveRead<Thread>('chat_thread', { id, after: last.current });
      setT(n);
      if (n.messages.length) { last.current = Math.max(last.current, ...n.messages.map((m) => m.id)); setMsgs((o) => [...o, ...n.messages.filter((m) => !o.some((x) => x.id === m.id))]); }
    } catch (e) { setNote(e instanceof Error ? e.message : 'Could not load'); }
  }, [id]);
  useEffect(() => {
    void load();
    const i = setInterval(() => { if (document.visibilityState === 'visible') void load(); }, 2000);
    return () => clearInterval(i);
  }, [load]);
  useEffect(() => { log.current?.scrollTo({ top: log.current.scrollHeight }); }, [msgs.length, t?.chat.visitor_typing]);

  const act = async (action: string, p: Record<string, unknown> = {}) => {
    setBusy(true); setNote('');
    try { await liveDo(action, { id, ...p }); await load(); onChange(); }
    catch (e) { setNote(e instanceof Error ? e.message : 'That did not work'); }
    setBusy(false);
  };
  if (!t) return <div className="lc-thread"><p className="small muted">Loading</p></div>;
  const c = t.chat;
  const s = t.session;
  const quote = portal === 'va' ? '/va/quotes/new' : '/admin/bookings/new';
  return (
    <div className="lc-main">
      <section className="lc-thread" aria-labelledby="lc-h" data-testid="chat-thread">
        <header className="lc-thread__head">
          <div><h2 className="d4" id="lc-h">{c.who} <span className="muted small">{c.number}</span></h2>
            <p className="small muted" data-testid="thread-status">{STATUS_WORDS[c.status]}{c.assigned_name ? `: ${c.assigned_name}` : ''}{c.human_reason && c.status !== 'ai' ? ` · ${c.human_reason}` : ''}{c.offline ? ' · left after hours' : ''}</p></div>
          <div className="lc-acts">
            {c.status !== 'closed' && !(c.status === 'human' && t.mine) && <button type="button" className="btn btn--primary btn--sm" disabled={busy} onClick={() => void act('chat_take')}>Take over</button>}
            {c.status === 'human' && <button type="button" className="btn btn--quiet btn--sm" disabled={busy} onClick={() => void act('chat_hand_back')}>Hand back to the assistant</button>}
            {c.status !== 'closed' && <button type="button" className="btn btn--quiet btn--sm" disabled={busy} onClick={() => void act('chat_close')}>Close</button>}
            {c.email && <button type="button" className="btn btn--quiet btn--sm" disabled={busy} onClick={() => void act('chat_transcript').then(() => setNote(`A copy goes to ${c.email}.`))}>Email the transcript</button>}
          </div>
        </header>
        <div className="lc-log" ref={log} role="log" aria-live="polite" aria-label="Messages">
          {msgs.map((m) => m.sender === 'system' ? <p key={m.id} className="ccw-sys lc-sys">{m.body}</p> : (
            <div key={m.id} className={`lc-msg lc-msg--${m.sender}`} data-sender={m.sender}>
              <span className="lc-msg__who">{m.sender === 'visitor' ? c.who : m.sender === 'ai' ? 'Assistant' : m.staff_name ?? m.name}{' '}<span className="muted">{clock(m.at)}</span></span>
              <p>{m.body}</p>
              {m.sender === 'ai' && Array.isArray((m.meta as { refused?: string[] })?.refused) && <span className="small muted">A reply was replaced by the rules: {((m.meta as { refused: string[] }).refused).join(', ')}</span>}
            </div>))}
          {c.visitor_typing && <p className="small muted">{c.who} is typing</p>}
        </div>
        {c.status !== 'closed' && (
          <form className="lc-form" onSubmit={async (e) => { e.preventDefault(); if (!text.trim()) return; const body = text; setText(''); await act('chat_reply', { body }); }}>
            <label className="vh" htmlFor="lc-reply">Reply</label>
            <textarea id="lc-reply" className="input" rows={2} maxLength={4000} value={text} placeholder={c.status === 'ai' ? 'Replying takes over from the assistant' : 'Write a reply'}
              onChange={(e) => { setText(e.target.value); if (Date.now() - typed.current > 3000) { typed.current = Date.now(); void liveDo('chat_typing', { id }).catch(() => undefined); } }}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); (e.currentTarget.form as HTMLFormElement).requestSubmit(); } }} />
            <button type="submit" className="btn btn--primary btn--sm" disabled={busy || !text.trim()}>Send</button>
          </form>)}
        {note && <p className="small" role="status">{note}</p>}
      </section>
      <aside className="lc-side" aria-label="The visitor">
        <h3 className="d4">The visitor</h3>
        <dl className="pt-dl ad-kv">
          {c.email && <div><dt>Email</dt><dd>{c.email}</dd></div>}
          {c.phone && <div><dt>Phone</dt><dd>{c.phone}</dd></div>}
          <div><dt>Started on</dt><dd>{c.page ?? 'the site'}{c.car ? `: ${c.car}` : ''}</dd></div>
          {s && <div><dt>Now</dt><dd>{c.online ? `${s.current_page ?? 'the site'}${s.car ? `: ${s.car}` : ''}` : `left ${agoWords(s.last_seen_at)}`}</dd></div>}
          {s && <div><dt>This visit</dt><dd>{s.page_views} pages, visit {s.visit_number}{s.city ? `, ${s.city}` : ''}{s.device ? `, ${s.device}` : ''}</dd></div>}
        </dl>
        {s && s.signals.length > 0 && <p className="lv-badges">{s.signals.map((g, i) => <span key={i} className={`lv-badge lv-badge--${g.kind}`}>{g.label}</span>)}</p>}
        {t.renter && (
          <div className="small"><p><b>{t.renter.name}</b>{portal === 'admin' && <> · <Link prefetch={false} className="link" href={`/admin/renters/${t.renter.id}`}>Renter page</Link></>}</p>
            {t.renter.bookings.length > 0 && <ul className="lc-bk">{t.renter.bookings.map((b) => <li key={b.number}><Link prefetch={false} className="link" href={`/${portal}/bookings/${encodeURIComponent(b.number)}`}>{b.number}</Link> <span className="muted">{b.status.replace(/_/g, ' ')}</span></li>)}</ul>}</div>)}
        {s && s.events.length > 0 && (<><h4 className="small">Pages</h4><ol className="lv-events">{s.events.filter((e) => e.kind !== 'page_leave').slice(0, 15).map((e, i) => (
          <li key={i}><span className="muted">{clock(e.at)}</span> {EVENT_WORDS[e.kind] ?? e.kind}{e.kind === 'page_view' ? ` ${e.page ?? ''}` : ''}{e.car ? `: ${e.car}` : ''}{e.booking_number ? ` (${e.booking_number})` : ''}</li>))}</ol></>)}
        <p className="small"><Link prefetch={false} className="link" href={quote}>{portal === 'va' ? 'New quote' : 'Add a rental'}</Link> <span className="muted">for this visitor. If you handled this chat, choose &quot;I sourced this client&quot;; nothing is credited by itself.</span></p>
      </aside>
    </div>
  );
}
