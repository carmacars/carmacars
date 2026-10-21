'use client';
import { SkeletonLines } from '@/components/Skeleton';
import '../live/live.css';
import './phone.css';
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
import { agoWords, clock, dayClock, EVENT_WORDS } from '../live/staff';
import { phoneDo, phoneRead, CallBody, type PhoneInboxData, type PhoneThreadData, type PhoneThreadRow } from './client';

// Live chat > Texts and calls (migration 0085): every number that called or texted the CarmaCars Quo line, newest first;
// Unknown callers with Create lead and Link to a renter; the thread with calls and texts, the reply box (sent through
// Quo from the CarmaCars number), Suggest a reply (an AI draft that only fills the box), and who the number is: their
// record, bookings and, when they gave this phone in live chat or a game, their visit on the site.
export function PhoneInbox({ initial, portal, openId }: { initial: PhoneInboxData; portal: 'admin' | 'va'; openId?: string }) {
  const [inbox, setInbox] = useState(initial);
  const [view, setView] = useState<'all' | 'unknown'>('all');
  const [sel, setSel] = useState<string | null>(openId ?? initial.threads[0]?.id ?? null);
  const [err, setErr] = useState('');
  const refresh = useCallback(async (v = view) => {
    try { setInbox(await phoneRead<PhoneInboxData>('phone_inbox', { view: v })); setErr(''); } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, [view]);
  useEffect(() => {
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, 6000);
    return () => clearInterval(t);
  }, [refresh]);
  const pick = (v: 'all' | 'unknown') => { setView(v); void refresh(v); };
  return (
    <div className="lc" data-testid="phone-inbox">
      <div className="lc-top">
        <p className="small">{inbox.unread ? <b className="lc-wait">{inbox.unread} unread text{inbox.unread === 1 ? '' : 's'}</b> : 'No unread texts.'}
          {' '}<span className="muted">Texts and calls to {inbox.number || 'the CarmaCars number'}.{inbox.enabled ? '' : ' Off in Program settings: nothing new is recorded.'}</span></p>
      </div>
      {err && <p className="pt-note" role="alert">{err}</p>}
      <div className="lc-grid">
        <nav className="lc-list" aria-label="Phone conversations">
          <div className="ad-chip-row" role="group" aria-label="Which numbers">
            <button type="button" className={`btn btn--sm ${view === 'all' ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={view === 'all'} onClick={() => pick('all')}>All</button>
            <button type="button" className={`btn btn--sm ${view === 'unknown' ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={view === 'unknown'} onClick={() => pick('unknown')} data-testid="phone-unknown-tab">Unknown callers<span> ({inbox.unknown})</span></button>
          </div>
          {!inbox.threads.length ? <p className="small muted">{view === 'unknown' ? 'Every number is matched to someone.' : 'No calls or texts yet. They appear here as they come in.'}</p> : (
            <ul>{inbox.threads.map((c) => (
              <li key={c.id}>
                <button type="button" className={`lc-item${sel === c.id ? ' is-on' : ''}`} aria-current={sel === c.id ? 'true' : undefined} onClick={() => setSel(c.id)} data-testid="phone-item">
                  <span className="lc-item__top"><b>{c.who}</b>{c.unread > 0 && <span className="lc-unread" aria-label={`${c.unread} unread`}>{c.unread}</span>}</span>
                  <span className="lc-item__meta"><span className={`ad-b ${c.match_kind === 'unknown' ? 'ad-b--wait' : 'ad-b--light'}`}>{KIND_WORDS[c.match_kind]}</span>
                    {c.missed > 0 && <span className="small lc-late">{c.missed} missed</span>}{c.opted_out && <span className="small muted">no texts</span>}</span>
                  <span className="small muted lc-item__last">{c.last_direction === 'out' ? 'You: ' : ''}{c.last ?? ''}</span>
                  <span className="small muted" suppressHydrationWarning>{c.display}{c.last_at ? ` · ${agoWords(c.last_at)}` : ''}</span>
                </button>
              </li>))}</ul>)}
        </nav>
        {sel ? <PhoneThread key={sel} id={sel} portal={portal} onChange={() => void refresh()} /> : <div className="lc-empty small muted">Choose a number.</div>}
      </div>
    </div>
  );
}

const KIND_WORDS: Record<PhoneThreadRow['match_kind'], string> = { staff: 'Staff', renter: 'Renter', owner: 'Owner', lead: 'Lead', unknown: 'Unknown caller' };

function PhoneThread({ id, portal, onChange }: { id: string; portal: 'admin' | 'va'; onChange: () => void }) {
  const [t, setT] = useState<PhoneThreadData | null>(null);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState('');
  const log = useRef<HTMLDivElement>(null);
  const changed = useRef(onChange);
  useEffect(() => { changed.current = onChange; }, [onChange]);
  const load = useCallback(async () => {
    try { const n = await phoneRead<PhoneThreadData>('phone_thread', { id }); setT(n); } catch (e) { setNote(e instanceof Error ? e.message : 'Could not load'); }
  }, [id]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- the first read of the thread; its state is set after the fetch
    void load();
    void phoneDo('phone_read', { id }).then(() => changed.current()).catch(() => undefined);
    const i = setInterval(() => { if (document.visibilityState === 'visible') void load(); }, 4000);
    return () => clearInterval(i);
  }, [load, id]);
  const count = t?.items.length ?? 0;
  useEffect(() => { log.current?.scrollTo({ top: log.current.scrollHeight }); }, [count]);

  const act = async (action: string, p: Record<string, unknown> = {}, done?: string) => {
    setBusy(true); setNote('');
    try { await phoneDo(action, { id, ...p }); await load(); onChange(); if (done) setNote(done); }
    catch (e) { setNote(e instanceof Error ? e.message : 'That did not work'); }
    setBusy(false);
  };
  const draft = async () => {
    setBusy(true); setNote('');
    try {
      const r = await phoneDo<{ ok: boolean; draft?: string; error?: string }>('phone_draft', { id });
      if (r.draft) { setText(r.draft); setNote('A suggestion is in the box. Check it, change it if needed, then send it yourself.'); } else setNote(r.error ?? 'No suggestion this time.');
    } catch (e) { setNote(e instanceof Error ? e.message : 'No suggestion this time.'); }
    setBusy(false);
  };
  if (!t) return <div className="lc-thread"><SkeletonLines lines={4} title /></div>;
  const c = t.thread;
  const bookingBase = `/${portal}/bookings/`;
  const canDraft = t.ai.drafts && t.ai.ok;
  return (
    <div className="lc-main">
      <section className="lc-thread" aria-labelledby="ph-h" data-testid="phone-thread">
        <header className="lc-thread__head">
          <div><h2 className="d4" id="ph-h">{c.who} <span className="muted small">{c.display}</span></h2>
            <p className="small muted">{KIND_WORDS[c.match_kind]}{c.booking_number ? ` · booking ${c.booking_number}` : ''}{c.opted_out ? ' · asked for no texts' : ''}</p></div>
          <div className="lc-acts">
            <a className="btn btn--quiet btn--sm" href={`tel:${c.number}`}>Call</a>
            {c.opted_out
              ? <button type="button" className="btn btn--quiet btn--sm" disabled={busy} onClick={() => void act('phone_opt_out', { on: false }, 'Texts allowed again.')}>Allow texts again</button>
              : <button type="button" className="btn btn--quiet btn--sm" disabled={busy} onClick={() => { if (confirm('Stop all texts to this number, booking texts included?')) void act('phone_opt_out', { on: true }, 'No more texts to this number.'); }}>Stop texts</button>}
          </div>
        </header>
        <div className="lc-log" ref={log} role="log" aria-live="polite" aria-label="Calls and texts">
          {t.items.map((m) => m.kind === 'call' ? (
            <div key={m.id} className={`ph-call${m.missed ? ' ph-call--missed' : ''}`} data-testid="phone-call">
              <p className="small"><b>{m.missed ? 'Missed call' : m.direction === 'in' ? 'Call in' : 'Call out'}</b> <span className="muted">{dayClock(m.at)}</span></p>
              <CallBody m={m} />
            </div>
          ) : (
            <div key={m.id} className={`lc-msg lc-msg--${m.direction === 'out' ? 'staff' : 'visitor'}`} data-direction={m.direction}>
              <span className="lc-msg__who">{m.direction === 'in' ? c.who : (m.by ?? (m.sms_kind && m.sms_kind !== 'staff' ? SMS_WORDS[m.sms_kind] ?? 'Automatic text' : 'CarmaCars'))} <span className="muted">{clock(m.at)}</span>
                {m.direction === 'out' && m.status && m.status !== 'sent' && <span className={`muted${m.status === 'failed' || m.status === 'undelivered' ? ' lc-late' : ''}`}> · {m.status}</span>}</span>
              <p>{m.body}</p>
              {m.media?.length > 0 && <span className="small">{m.media.map((x, i) => <a key={i} className="link" href={x.url} target="_blank" rel="noreferrer noopener">Picture {i + 1}</a>)}</span>}
            </div>))}
          {!t.items.length && <p className="lc-sys">Nothing recorded with this number yet.</p>}
        </div>
        {c.opted_out ? <p className="small muted ph-pad">This number asked for no texts (STOP). They can text START to allow them again.</p> : (
          <form className="lc-form ph-form" onSubmit={async (e) => { e.preventDefault(); if (!text.trim()) return; const body = text; setBusy(true); setNote('');
            try { const r = await phoneDo<{ ok: boolean; error?: string }>('phone_reply', { id, body }); if (!r.ok) setNote(r.error ?? 'Not sent'); else setText(''); await load(); onChange(); }
            catch (er) { setNote(er instanceof Error ? er.message : 'Not sent'); }
            setBusy(false); }}>
            <label className="vh" htmlFor="ph-reply">Text to {c.display}</label>
            <textarea id="ph-reply" className="input" rows={2} maxLength={1600} value={text} placeholder={`Text from the CarmaCars number`} onChange={(e) => setText(e.target.value)} />
            <div className="ph-formacts">
              {t.ai.drafts && <button type="button" className="btn btn--quiet btn--sm" disabled={busy || !canDraft} onClick={() => void draft()} title={canDraft ? undefined : 'The AI allowance for today is used'} data-testid="phone-suggest">Suggest a reply</button>}
              <button type="submit" className="btn btn--primary btn--sm" disabled={busy || !text.trim()}>Send text</button>
            </div>
          </form>)}
        {note && <p className="small ph-pad" role="status">{note}</p>}
      </section>
      <aside className="lc-side" aria-label="Who this is">
        <h3 className="d4">Who this is</h3>
        <Who t={t} portal={portal} bookingBase={bookingBase} onLinked={() => { void load(); onChange(); }} />
        {t.visit && (
          <div className="small" data-testid="phone-visit">
            <h4 className="small">On the site</h4>
            <p className="muted" suppressHydrationWarning>{t.visit.current_page ? `Now: ${t.visit.current_page}${t.visit.car ? `: ${t.visit.car}` : ''}. ` : ''}Last seen {agoWords(t.visit.last_seen_at)}, visit {t.visit.visit_number}{t.visit.city ? `, ${t.visit.city}` : ''}.</p>
            {t.visit.events.length > 0 && <ol className="lv-events">{t.visit.events.filter((e) => e.kind !== 'page_leave').slice(0, 10).map((e, i) => (
              <li key={i}><span className="muted">{clock(e.at)}</span> {EVENT_WORDS[e.kind] ?? e.kind}{e.kind === 'page_view' ? ` ${e.page ?? ''}` : ''}{e.car ? `: ${e.car}` : ''}</li>))}</ol>}
            <Link prefetch={false} className="link" href={`/${portal}/live`}>Live visitors</Link>
          </div>)}
      </aside>
    </div>
  );
}

const SMS_WORDS: Record<string, string> = { missed_call: 'Missed-call text', offer_sent: 'Booking text: offer', payment_confirmed: 'Booking text: confirmed', payment_received: 'Booking text: payment',
  pickup_tomorrow: 'Booking text: pickup tomorrow', return_reminder: 'Booking text: return', payment_link: 'Booking text: payment link' };

function Who({ t, portal, bookingBase, onLinked }: { t: PhoneThreadData; portal: 'admin' | 'va'; bookingBase: string; onLinked: () => void }) {
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Array<{ id: string; name: string; email: string | null; mobile: string | null }>>([]);
  const [name, setName] = useState(t.thread.name ?? '');
  const [msg, setMsg] = useState('');
  const id = t.thread.id;
  const run = async (action: string, p: Record<string, unknown>, done: string) => {
    setMsg('');
    try { await phoneDo(action, { id, ...p }); setMsg(done); onLinked(); } catch (e) { setMsg(e instanceof Error ? e.message : 'That did not work'); }
  };
  return (
    <div className="small stack">
      {t.renter && <div><p><b>{t.renter.name}</b> <span className="muted">renter</span>{portal === 'admin' && <> · <Link prefetch={false} className="link" href={`/admin/renters/${t.renter.id}`}>Renter page</Link></>}</p>
        {t.renter.bookings.length > 0 && <ul className="lc-bk">{t.renter.bookings.map((b) => <li key={b.number}><Link prefetch={false} className="link" href={`${bookingBase}${encodeURIComponent(b.number)}`}>{b.number}</Link> <span className="muted">{b.status.replace(/_/g, ' ')}</span></li>)}</ul>}</div>}
      {t.owner && <p><b>{t.owner.name}</b> <span className="muted">owner</span>{portal === 'admin' && <> · <Link prefetch={false} className="link" href={`/admin/owners/${t.owner.id}`}>Owner page</Link></>}</p>}
      {t.lead && <p><b>{t.lead.name ?? 'Lead'}</b> <span className="muted">lead ({t.lead.kind.replace(/_/g, ' ')}, {t.lead.status})</span></p>}
      {t.staff && <p><b>{t.staff.name}</b> <span className="muted">staff</span></p>}
      {!t.renter && !t.owner && !t.lead && !t.staff && <p className="muted">Nobody on file has this number.</p>}
      {!t.renter && !t.owner && !t.staff && (
        <div className="ph-link" data-testid="phone-link">
          {!t.lead && <form onSubmit={(e) => { e.preventDefault(); void run('phone_create_lead', { name }, 'Lead created.'); }} className="ph-row">
            <label className="vh" htmlFor="ph-name">Name</label>
            <input id="ph-name" className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Name (if you know it)" maxLength={120} />
            <button type="submit" className="btn btn--primary btn--sm">Create lead</button>
          </form>}
          <form onSubmit={async (e) => { e.preventDefault(); try { setFound(await phoneRead('phone_renter_search', { q })); } catch { setFound([]); } }} className="ph-row">
            <label className="vh" htmlFor="ph-q">Find a renter</label>
            <input id="ph-q" className="input" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Renter name, email or phone" />
            <button type="submit" className="btn btn--quiet btn--sm">Find</button>
          </form>
          {found.length > 0 && <ul className="ph-found">{found.map((r) => <li key={r.id}><button type="button" className="btn btn--quiet btn--sm" onClick={() => void run('phone_link', { renter_id: r.id }, `Linked to ${r.name}.`)}>Link to {r.name}</button> <span className="muted">{r.email ?? r.mobile ?? ''}</span></li>)}</ul>}
        </div>)}
      {t.thread.manual && <button type="button" className="btn btn--quiet btn--sm" onClick={() => void run('phone_link', { automatic: true }, 'Matched automatically again.')}>Match automatically again</button>}
      {msg && <p role="status">{msg}</p>}
    </div>
  );
}
