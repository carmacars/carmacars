'use client';
import './live.css';
import Link from 'next/link';
import { useCallback, useEffect, useState } from 'react';
import { agoWords, clock, EVENT_WORDS, liveDo, liveRead, type LiveData, type SessionDetail, type Visitor } from './staff';

// Admin > Today > Live visitors and the assistants' My work > Live visitors (migration 0060): who is on the site now,
// what they look at, the buying signals, the most viewed cars; start a chat with a visitor. Refreshed every 5 seconds
// (one small read; nothing stays open).
export function LiveVisitors({ initial, portal }: { initial: LiveData; portal: 'admin' | 'va' }) {
  const [data, setData] = useState(initial);
  const [err, setErr] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const refresh = useCallback(async () => {
    try { setData(await liveRead<LiveData>('live_visitors')); setErr(''); } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, []);
  useEffect(() => {
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, 5000);
    return () => clearInterval(t);
  }, [refresh]);
  const chatHref = portal === 'admin' ? '/admin/chat' : '/va/chat';
  const known = data.now.filter((v) => v.known).length;
  return (
    <div className="lv" data-testid="live-visitors">
      <div className="ad-tiles">
        <div className="ad-tile"><span className="ad-tile__k">On the site now</span><b className="ad-tile__v" data-testid="live-count">{data.now.length}</b><span className="ad-tile__s">seen in the last {data.live_minutes} min</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Known customers now</span><b className="ad-tile__v">{known}</b></div>
        <div className="ad-tile"><span className="ad-tile__k">Visits today</span><b className="ad-tile__v">{data.today.sessions}</b><span className="ad-tile__s">{data.today.known} known</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Chats today</span><b className="ad-tile__v">{data.today.chats}</b><Link prefetch={false} className="ad-tile__s link" href={chatHref}>Open Live chat</Link></div>
      </div>
      {!data.tracking && <p className="pt-note" role="status">Live visitors is off in Program settings: nothing is recorded.</p>}
      {err && <p className="pt-note" role="alert">{err}</p>}
      <section className="pt-card ad-card" aria-labelledby="lv-now">
        <div className="pt-card__head"><h2 className="d4" id="lv-now">On the site now</h2><span className="small muted" aria-live="polite">Updated {clock(data.at)}</span></div>
        {!data.now.length ? <p className="small muted">Nobody right now. Visitors who accepted analytics, known customers on their booking pages and anyone in a chat appear here.</p> : (
          <ul className="lv-list">
            {data.now.map((v) => <VisitorRow key={v.id} v={v} portal={portal} open={open === v.id} onToggle={() => setOpen(open === v.id ? null : v.id)} onChat={refresh} />)}
          </ul>)}
      </section>
      <div className="lv-cols">
        <section className="pt-card ad-card" aria-labelledby="lv-sig" data-testid="live-signals">
          <div className="pt-card__head"><h2 className="d4" id="lv-sig">Signals in the last 24 hours</h2></div>
          {!data.signals.length ? <p className="small muted">No signals yet.</p> : (
            <ul className="lv-sigs">{data.signals.map((s, i) => (
              <li key={`${s.kind}-${i}`}><span className={`lv-badge lv-badge--${s.kind}`}>{s.label}</span> <span className="small">{s.who}</span> <span className="small muted">{agoWords(s.at)}</span>
                {s.task_id ? <span className="small muted"> · follow-up task raised</span> : null}</li>))}</ul>)}
        </section>
        <section className="pt-card ad-card" aria-labelledby="lv-cars" data-testid="most-viewed">
          <div className="pt-card__head"><h2 className="d4" id="lv-cars">Most viewed cars (7 days)</h2></div>
          {!data.most_viewed.length ? <p className="small muted">No car views yet.</p> : (
            <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Most viewed cars"><table className="ad-table ad-table--dense"><caption className="vh">Most viewed cars</caption>
              <thead><tr><th scope="col">Car</th><th scope="col">Today</th><th scope="col">7 days</th><th scope="col">Looking now</th><th scope="col">Requests</th></tr></thead>
              <tbody>{data.most_viewed.map((c) => (
                <tr key={c.vehicle_id}><td>{portal === 'admin' ? <Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}`}>{c.car}</Link> : c.car}</td>
                  <td>{c.views_today}</td><td>{c.views_7d}</td><td>{c.looking_now}</td><td>{c.requests_7d}</td></tr>))}</tbody></table></div>)}
        </section>
      </div>
    </div>
  );
}

function VisitorRow({ v, portal, open, onToggle, onChat }: { v: Visitor; portal: 'admin' | 'va'; open: boolean; onToggle: () => void; onChat: () => void }) {
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [composing, setComposing] = useState(false);
  const [text, setText] = useState('');
  const [msg, setMsg] = useState('');
  useEffect(() => {
    if (!open) return;
    let live = true;
    void liveRead<SessionDetail>('live_session', { id: v.id }).then((d) => { if (live) setDetail(d); }).catch(() => undefined);
    return () => { live = false; };
  }, [open, v.id, v.last_seen_at]);
  const chatHref = portal === 'admin' ? '/admin/chat' : '/va/chat';
  return (
    <li className="lv-row" data-testid="live-row">
      <div className="lv-row__main">
        <div className="lv-who"><b>{v.who}</b>{v.known && <span className="ad-b ad-b--dark">Known</span>}
          {v.renter_id && portal === 'admin' && <Link prefetch={false} className="link small" href={`/admin/renters/${v.renter_id}`}>Renter page</Link>}</div>
        <p className="small"><span className="muted">Now on </span>{v.current_page ?? 'the site'}{v.car ? `: ${v.car}` : ''}{v.booking_number ? ` (${v.booking_number})` : ''}
          <span className="muted"> · {v.page_views} page{v.page_views === 1 ? '' : 's'} this visit{v.cars_viewed ? `, ${v.cars_viewed} car${v.cars_viewed === 1 ? '' : 's'}` : ''} · visit {v.visit_number}</span></p>
        <p className="small muted">{[v.device, v.city, v.referrer ? `from ${v.referrer}` : null, v.utm_source ? `campaign ${v.utm_source}${v.utm_campaign ? `/${v.utm_campaign}` : ''}` : null].filter(Boolean).join(' · ')} · since {clock(v.started_at)}</p>
        {v.signals.length > 0 && <p className="lv-badges">{v.signals.map((s, i) => <span key={i} className={`lv-badge lv-badge--${s.kind}`} data-testid="signal-badge">{s.label}</span>)}</p>}
      </div>
      <div className="lv-row__acts">
        {v.chat ? <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${chatHref}?id=${v.chat.id}`}>Open chat {v.chat.number}</Link>
          : <button type="button" className="btn btn--primary btn--sm" onClick={() => setComposing(!composing)} aria-expanded={composing}>Start a chat</button>}
        <button type="button" className="btn btn--quiet btn--sm" onClick={onToggle} aria-expanded={open}>{open ? 'Hide pages' : 'Pages'}</button>
      </div>
      {composing && (
        <form className="lv-compose" onSubmit={async (e) => {
          e.preventDefault();
          try { const r = await liveDo<{ id: string; number: string }>('chat_start', { session_id: v.id, body: text }); setMsg(`Chat ${r.number} started. The visitor sees your message.`); setComposing(false); onChat(); }
          catch (er) { setMsg(er instanceof Error ? er.message : 'That did not work'); }
        }}>
          <label className="small" htmlFor={`lvc-${v.id}`}>Your message (the visitor sees it in a bubble)</label>
          <textarea id={`lvc-${v.id}`} className="input" rows={2} maxLength={1000} value={text} placeholder="Hi, I am here if you have a question about this car." onChange={(e) => setText(e.target.value)} />
          <button type="submit" className="btn btn--primary btn--sm">Send</button>
        </form>)}
      {msg && <p className="small" role="status">{msg}</p>}
      {open && (
        <div className="lv-detail">
          {!detail ? <p className="small muted">Loading</p> : (
            <>
              <p className="small muted">{detail.visits} visit{detail.visits === 1 ? '' : 's'} in all, {detail.visits_7d} this week{detail.email ? ` · ${detail.email}` : ''}</p>
              <ol className="lv-events">{detail.events.filter((e) => e.kind !== 'page_leave').map((e, i) => (
                <li key={i}><span className="muted">{clock(e.at)}</span> {EVENT_WORDS[e.kind] ?? e.kind}{e.kind === 'page_view' ? ` ${e.page ?? e.path}` : ''}{e.car ? `: ${e.car}` : ''}
                  {e.booking_number ? ` (${e.booking_number})` : ''}{e.pickup ? ` ${e.pickup} to ${e.return}` : ''}</li>))}</ol>
            </>)}
        </div>)}
    </li>
  );
}
