'use client';
import { SkeletonLines } from '@/components/Skeleton';
import './live.css';
import Link from '@/components/Link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ACTION_WORDS, agoWords, clock, EVENT_WORDS, GROUP_WORDS, liveDo, liveRead, STRENGTH_WORDS, type LiveCfg, type LiveData, type SessionDetail, type Signal, type Visitor } from './staff';
import { useContact } from '@/features/live-map/contact';
import { liveWithoutContact } from './contact';
import { showOnMap } from '@/features/live-map/focus';
import { personPages, roleLabel } from '@/features/live-map/roles';
import { poller } from '@/lib/poll/poll';

// Admin > Today > Live visitors and the assistants' My work > Live visitors (migration 0060): who is on the site now,
// what they look at, the buying signals, the most viewed cars; start a chat with a visitor. Refreshed every 15 seconds
// while the page is visible, and at once when it is shown again (one small read; nothing stays open; 0103: was 5
// seconds, which cost the database more than it showed). 0086: each visit has a booking likelihood (0 to 100) with its top reasons, the
// list is sorted by it, every signal says why and how strong it is, and the suggested action is one click: invite to
// chat with the suggested message, send a discount code, assign to Sales, suggest a similar free car. A visitor who
// turns hot raises an alert on this page (a desktop alert only when turned on in Live chat, never in the quiet hours).
const BAND_WORDS = { hot: 'Hot', warm: 'Warm', cold: 'Cold' } as const;
const SEEN_KEY = 'cc_hot_seen';
const REFRESH_MS = 15_000;

/** Release 26: what a live visit is, for its icon and its line (the same words as the map's lead types). */
export function liveKind(v: Visitor): { key: 'chat' | 'form' | 'draft' | 'known' | 'visitor'; label: string } {
  if (v.chat) return { key: 'chat', label: 'In a chat' };
  if (v.captured?.done) return { key: 'form', label: 'Form sent' };
  if (v.captured) return { key: 'draft', label: 'Unfinished form' };
  if (v.known || v.renter_id || v.roles?.length) return { key: 'known', label: roleLabel(v.roles) ?? 'Known customer' };
  return { key: 'visitor', label: 'On the site now' };
}
const sourceOf = (v: Visitor) => v.utm_source || v.referrer || (v.from_ad ? 'an ad' : 'direct');

export function LiveVisitors({ initial, portal, inVisitors = false }: { initial: LiveData; portal: 'admin' | 'va';
  /** Release 26: on the Visitors page, under the map: Show contact decides the phones and emails, rows find their lead on the map, filters */
  inVisitors?: boolean }) {
  const contactOn = useContact();
  // off the Visitors page (the assistants' Live visitors) nothing changes: contact details as before
  const contact = inVisitors ? contactOn : true;
  const [raw, setData] = useState(initial);
  const [kind, setKind] = useState('');
  const [city, setCity] = useState('');
  const [source, setSource] = useState('');
  const [err, setErr] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const [sort, setSort] = useState<'score' | 'recent'>('score');
  const [only, setOnly] = useState(false);
  const [alert, setAlert] = useState<Visitor | null>(null);
  const seen = useRef<Set<string> | null>(null);
  const refresh = useCallback(async () => {
    try {
      const d = await liveRead<LiveData>('live_visitors', inVisitors ? { contact: contact ? '1' : '0' } : {});
      setData(contact ? d : liveWithoutContact(d)); setErr('');
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, [inVisitors, contact]);
  // Show contact turned on or off: asked for again at once (and while it is off, the rows below never show what an
  // earlier answer had: `shown` strips it)
  useEffect(() => {
    if (!inVisitors) return;
    const t = setTimeout(() => void refresh(), 0);
    return () => clearTimeout(t);
  }, [inVisitors, contact, refresh]);
  const data = useMemo(() => (contact ? raw : liveWithoutContact(raw)), [raw, contact]);
  useEffect(() => {
    // 0320: once a minute when nobody touched the screen for two (lib/poll)
    const due = poller(REFRESH_MS);
    const t = setInterval(() => { if (due()) void refresh(); }, REFRESH_MS);
    const shown = () => { if (document.visibilityState === 'visible') void refresh(); };
    document.addEventListener('visibilitychange', shown);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', shown); };
  }, [refresh]);
  const cfg: LiveCfg = data.cfg ?? { hot: 60, warm: 30, notify_hot: false, discount: { enabled: false, percent: 0, days: 0, can: false }, is_admin: false, quiet: false, me: null, alerts: false };

  // a visitor who turned hot since this page opened: an alert here, and on the desktop when the person asked for it
  useEffect(() => {
    if (!seen.current) {
      let kept: string[] = [];
      try { kept = JSON.parse(sessionStorage.getItem(SEEN_KEY) ?? '[]') as string[]; } catch { /* none */ }
      seen.current = new Set([...kept, ...data.now.filter((v) => v.band === 'hot').map((v) => v.id)]);
      return;
    }
    if (!cfg.notify_hot) return;
    const fresh = data.now.filter((v) => v.band === 'hot' && !seen.current!.has(v.id));
    if (!fresh.length) return;
    for (const v of fresh) seen.current.add(v.id);
    try { sessionStorage.setItem(SEEN_KEY, JSON.stringify([...seen.current].slice(-200))); } catch { /* none */ }
    const v = fresh[0]!;
    setAlert(v);
    if (cfg.alerts && !cfg.quiet && typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      try { new Notification(`Hot visitor: ${v.who} (${v.score})`, { body: (v.reasons ?? []).map((r) => r.label).join(', '), tag: `cc-hot-${v.id}` }); } catch { /* not allowed */ }
    }
  }, [data, cfg.notify_hot, cfg.alerts, cfg.quiet]);

  const rows = useMemo(() => {
    const list = data.now.filter((v) => (!only || v.band === 'hot' || v.band === 'warm') && (!kind || liveKind(v).key === kind)
      && (!city || v.city === city) && (!source || sourceOf(v) === source));
    return sort === 'recent' ? [...list].sort((a, b) => b.last_seen_at.localeCompare(a.last_seen_at)) : list;
  }, [data.now, sort, only, kind, city, source]);
  const cities = useMemo(() => [...new Set(data.now.map((v) => v.city).filter((c): c is string => !!c))].sort(), [data.now]);
  const sources = useMemo(() => [...new Set(data.now.map(sourceOf))].sort(), [data.now]);
  const chatHref = portal === 'admin' ? '/admin/chat' : '/staff/chat';
  const known = data.now.filter((v) => v.known).length;
  const hotNow = data.now.filter((v) => v.band === 'hot').length;
  const visitorsToday = data.today.visitors ?? data.today.sessions;
  const untracked = data.today.untracked ?? 0;
  return (
    <div className="lv" data-testid="live-visitors">
      {inVisitors ? (
        // Release 26: under the map, which has the big numbers already: one quiet line
        <p className="vs-stats" data-testid="lv-stats">
          <span><b data-testid="live-count">{data.now.length}</b> live now</span>
          <span><b data-testid="visitors-today">{visitorsToday}</b> visitors today ({data.today.sessions} visit{data.today.sessions === 1 ? '' : 's'})</span>
          <span><b data-testid="hot-count">{hotNow}</b> hot now</span>
          <span><b>{known}</b> known customer{known === 1 ? '' : 's'} now</span>
          <span><b>{data.today.chats}</b> chat{data.today.chats === 1 ? '' : 's'} today</span>
        </p>
      ) : <div className="ad-tiles">
        <div className="ad-tile"><span className="ad-tile__k">Live now</span><b className="ad-tile__v" data-testid="live-count">{data.now.length}</b><span className="ad-tile__s">on the site in the last {data.live_minutes} min</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Visitors today</span><b className="ad-tile__v" data-testid="visitors-today">{visitorsToday}</b><span className="ad-tile__s">{data.today.sessions} visit{data.today.sessions === 1 ? '' : 's'}, {data.today.known} known, {data.today.hot ?? 0} hot</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Hot now</span><b className="ad-tile__v" data-testid="hot-count">{hotNow}</b><span className="ad-tile__s">likelihood {cfg.hot} or more</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Known customers now</span><b className="ad-tile__v">{known}</b></div>
        <div className="ad-tile"><span className="ad-tile__k">Chats today</span><b className="ad-tile__v">{data.today.chats}</b><Link prefetch={false} className="ad-tile__s link" href={chatHref}>Open Live chat</Link></div>
      </div>}
      {!data.tracking ? <p className="pt-note" role="status" data-testid="live-untracked">Live visitors is off in Program settings: nothing is recorded, so nobody is counted here.</p>
        : untracked > 0 && <p className="small muted" data-testid="live-untracked">Not counted: {untracked} visitor{untracked === 1 ? '' : 's'} today chose necessary cookies only, so their visits are not recorded. Visitors who have not answered the cookie banner (where we ask first) are not counted either.</p>}
      {err && <p className="pt-note" role="alert">{err}</p>}
      <div role="status" aria-live="polite">
        {alert && (
          <p className="lv-alert" data-testid="hot-alert"><b>Hot visitor: {alert.who}</b> <span className="lv-score lv-score--hot">{alert.score}</span>{' '}
            <span className="small">{(alert.reasons ?? []).map((r) => r.label).join(', ')}</span>{' '}
            <a className="link small" href={`#lv-${alert.id}`} onClick={() => setOpen(alert.id)}>Show</a>{' '}
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setAlert(null)}>Dismiss</button></p>)}
      </div>
      <section className="pt-card ad-card" aria-labelledby="lv-now">
        <div className="pt-card__head lv-head"><h2 className="d4" id="lv-now">On the site now</h2>
          <div className="lv-tools">
            <label className="small lv-tool"><span>Sort</span>
              <select className="select lv-select" value={sort} onChange={(e) => setSort(e.target.value as 'score' | 'recent')} data-testid="lv-sort">
                <option value="score">Booking likelihood</option><option value="recent">Most recent</option></select></label>
            <label className="check small"><input type="checkbox" checked={only} onChange={(e) => setOnly(e.target.checked)} /><span>Hot and warm only</span></label>
            {inVisitors && <>
              <label className="small lv-tool"><span>Type</span>
                <select className="select lv-select" value={kind} onChange={(e) => setKind(e.target.value)} data-testid="lv-kind">
                  <option value="">Everyone</option><option value="chat">In a chat</option><option value="form">Form sent</option><option value="draft">Unfinished form</option>
                  <option value="known">Known customer</option><option value="visitor">Other visitors</option></select></label>
              <label className="small lv-tool"><span>City</span>
                <select className="select lv-select" value={city} onChange={(e) => setCity(e.target.value)} data-testid="lv-city">
                  <option value="">Any</option>{cities.map((c) => <option key={c} value={c}>{c}</option>)}</select></label>
              <label className="small lv-tool"><span>Source</span>
                <select className="select lv-select" value={source} onChange={(e) => setSource(e.target.value)} data-testid="lv-source">
                  <option value="">Any</option>{sources.map((c) => <option key={c} value={c}>{c.length > 32 ? `${c.slice(0, 31)}…` : c}</option>)}</select></label>
            </>}
            {cfg.is_admin && portal === 'admin' && <Link prefetch={false} className="link small" href="/admin/live/signals" data-testid="signal-settings-link">Signal settings</Link>}
            <span className="small muted" aria-live="polite">Updated {clock(data.at)}</span>
          </div></div>
        {!rows.length ? <p className="small muted">{data.now.length ? (only && !kind && !city && !source ? 'No hot or warm visitor right now.' : 'Nobody matches these filters right now.') : 'Nobody right now. Visitors who accepted analytics, known customers on their booking pages and anyone in a chat appear here.'}</p> : (
          <ul className="lv-list">
            {rows.map((v) => <VisitorRow key={v.id} v={v} cfg={cfg} portal={portal} open={open === v.id} onToggle={() => setOpen(open === v.id ? null : v.id)} onChat={refresh}
              inVisitors={inVisitors} contact={contact} />)}
          </ul>)}
      </section>
      <div className="lv-cols">
        <section className="pt-card ad-card" aria-labelledby="lv-hot" data-testid="hot-today">
          <div className="pt-card__head"><h2 className="d4" id="lv-hot">Hot visitors today</h2></div>
          {!data.hot?.length ? <p className="small muted">No hot visitor yet today.</p> : (
            <ul className="lv-sigs">{data.hot.map((h) => (
              <li key={h.id}><span className="lv-score lv-score--hot" aria-label={`Likelihood ${h.score}`}>{h.score}</span> <span className="small">{portal === 'admin' && personPages(h)[0] ? <Link prefetch={false} className="link" href={personPages(h)[0]!.href}>{h.who}</Link> : h.who}</span>
                {' '}<span className="small muted" suppressHydrationWarning>{agoWords(h.hot_at)}{h.online ? ', on the site now' : ''}{h.acted ? ', acted on' : ''}</span>
                <br /><span className="small muted">{h.reasons.map((r) => r.label).join(', ')}</span></li>))}</ul>)}
        </section>
        <section className="pt-card ad-card" aria-labelledby="lv-sig" data-testid="live-signals">
          <div className="pt-card__head"><h2 className="d4" id="lv-sig">Signals in the last 24 hours</h2></div>
          {!data.signals.length ? <p className="small muted">No signals yet.</p> : (
            <ul className="lv-sigs">{data.signals.map((s, i) => (
              <li key={`${s.kind}-${i}`}><SignalBadge s={s} /> <span className="small">{s.who}</span> <span className="small muted" suppressHydrationWarning>{agoWords(s.at)}</span>
                {s.why && s.why !== s.label ? <span className="small muted"> · {s.why}</span> : null}
                {s.task_id ? <span className="small muted"> · follow-up task raised</span> : null}</li>))}</ul>)}
        </section>
      </div>
      <section className="pt-card ad-card" aria-labelledby="lv-cars" data-testid="most-viewed">
        <div className="pt-card__head"><h2 className="d4" id="lv-cars">Most viewed cars (7 days)</h2></div>
        {!data.most_viewed.length ? <p className="small muted">No car views yet.</p> : (
          <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Most viewed cars"><table className="ad-table ad-table--dense"><caption className="vh">Most viewed cars</caption>
            <thead><tr><th scope="col">Car</th><th scope="col">Today</th><th scope="col">7 days</th><th scope="col">Looking now</th><th scope="col">Prices shown</th><th scope="col">Requests</th><th scope="col">Most compared with</th></tr></thead>
            <tbody>{data.most_viewed.map((c) => (
              <tr key={c.vehicle_id}><td>{portal === 'admin' ? <Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}`}>{c.car}</Link> : c.car}</td>
                <td>{c.views_today}</td><td>{c.views_7d}</td><td>{c.looking_now}</td><td>{c.quotes_7d ?? 0}</td><td>{c.requests_7d}</td><td>{c.compared?.car ?? ''}</td></tr>))}</tbody></table></div>)}
      </section>
    </div>
  );
}

// 0190: staff name a visitor once they learn who it is. The name is kept for the browser (every later visit), shows on
// Live visitors, Visitor history and Live chat, and is never shown to the visitor. A phone makes a Quo contact.
function NameForm({ v, onDone, contact = true }: { v: Visitor; onDone: (msg: string) => void; contact?: boolean }) {
  const l = v.label ?? null;
  const [name, setName] = useState(l?.name ?? '');
  const [phone, setPhone] = useState(l?.phone ?? '');
  const [email, setEmail] = useState(l?.email ?? '');
  const [note, setNote] = useState(l?.note ?? '');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const idp = `lvn-${v.id}`;
  const send = async (remove: boolean) => {
    setBusy(true); setErr('');
    try {
      await liveDo('live_name', remove ? { session_id: v.id, remove: true } : { session_id: v.id, name, phone, email, note });
      onDone(remove ? 'Name removed.' : `Named ${name.trim()}. Every visit from this browser shows the name.`);
    } catch (e) { setErr(e instanceof Error ? e.message : 'That did not work'); } finally { setBusy(false); }
  };
  // Release 26: with Show contact off the form has no phone or email to show, so a name with them waits for the switch
  // (saving here would wipe them)
  if (!contact && l) return <p className="lv-compose small" data-testid="name-form">Turn on <b>Show contact</b> above the map to change this name and its phone and email.</p>;
  return (
    <form className="lv-compose" data-testid="name-form" onSubmit={(e) => { e.preventDefault(); void send(false); }}>
      <p className="small muted">Only staff see this name. A phone number also saves them as a contact in Quo.</p>
      <label className="small" htmlFor={`${idp}-n`}>Name</label>
      <input id={`${idp}-n`} className="input" required maxLength={120} autoComplete="off" value={name} onChange={(e) => setName(e.target.value)} />
      <label className="small" htmlFor={`${idp}-p`}>Phone (optional)</label>
      <input id={`${idp}-p`} className="input" type="tel" maxLength={30} autoComplete="off" value={phone} onChange={(e) => setPhone(e.target.value)} />
      <label className="small" htmlFor={`${idp}-e`}>Email (optional)</label>
      <input id={`${idp}-e`} className="input" type="email" maxLength={254} autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} />
      <label className="small" htmlFor={`${idp}-x`}>Note (optional)</label>
      <input id={`${idp}-x`} className="input" maxLength={500} autoComplete="off" value={note} placeholder="For example: asked about the van by phone" onChange={(e) => setNote(e.target.value)} />
      {err && <p className="small" role="alert">{err}</p>}
      <p className="lv-sug__acts">
        <button type="submit" className="btn btn--primary btn--sm" disabled={busy || !name.trim()} data-testid="name-save">Save the name</button>
        {l && <button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={() => void send(true)} data-testid="name-remove">Remove the name</button>}
      </p>
    </form>
  );
}

function SignalBadge({ s }: { s: Signal }) {
  const st = s.strength ?? 0;
  return (
    <span className={`lv-badge lv-badge--${s.kind} lv-badge--s${st}`} data-testid="signal-badge" title={s.why && s.why !== s.label ? s.why : undefined}>
      {st > 0 && <span className="lv-dots" aria-hidden="true">{'●'.repeat(st)}{'○'.repeat(3 - st)}</span>}{s.label}
      {st > 0 && <span className="vh">, {STRENGTH_WORDS[st]} signal</span>}
    </span>
  );
}

function VisitorRow({ v, cfg, portal, open, onToggle, onChat, inVisitors = false, contact = true }: { v: Visitor; cfg: LiveCfg; portal: 'admin' | 'va'; open: boolean; onToggle: () => void; onChat: () => void;
  inVisitors?: boolean; contact?: boolean }) {
  const [detail, setDetail] = useState<SessionDetail | null>(null);
  const [composing, setComposing] = useState(false);
  const [naming, setNaming] = useState(false);
  const [text, setText] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!open) return;
    let live = true;
    void liveRead<SessionDetail>('live_session', inVisitors ? { id: v.id, contact: contact ? '1' : '0' } : { id: v.id }).then((d) => { if (live) setDetail(d); }).catch(() => undefined);
    return () => { live = false; };
  }, [open, v.id, v.last_seen_at, inVisitors, contact]);
  const chatHref = portal === 'admin' ? '/admin/chat' : '/staff/chat';
  const sug = v.suggested ?? null;
  const preview = (sug?.message ?? '').replaceAll('{staff}', cfg.me ?? '');
  const act = async (f: () => Promise<string>) => {
    setBusy(true);
    try { setMsg(await f()); onChat(); } catch (er) { setMsg(er instanceof Error ? er.message : 'That did not work'); } finally { setBusy(false); }
  };
  const invite = (body: string, kind?: string) => act(async () => { const r = await liveDo<{ number: string }>('live_invite', { session_id: v.id, body, kind }); return `Chat ${r.number} started. The visitor sees your message.`; });
  const discount = () => act(async () => { const r = await liveDo<{ number: string; code: string }>('live_discount', { session_id: v.id, kind: sug?.kind }); return `Code ${r.code} sent in chat ${r.number}.`; });
  const assign = () => act(async () => { const r = await liveDo<{ name: string | null }>('live_assign', { session_id: v.id, kind: sug?.kind }); return r.name ? `Assigned to ${r.name}, with a task.` : 'A task is waiting for Sales.'; });
  const similar = async () => {
    setBusy(true);
    try { const r = await liveRead<{ message: string; cars: unknown[] }>('live_similar', { session_id: v.id }); setText(r.message); setComposing(true); setMsg(r.cars.length ? 'Check the message, then press Send.' : 'No similar car is free for those dates.'); }
    catch (er) { setMsg(er instanceof Error ? er.message : 'That did not work'); } finally { setBusy(false); }
  };
  const band = v.band ?? null;
  const k = liveKind(v);
  const locate = () => { if (!showOnMap({ session_id: v.id, renter_id: v.renter_id })) setMsg('This visit has no place on the map.'); };
  return (
    <li className={`lv-row${band ? ` lv-row--${band}` : ''}${inVisitors ? ' lv-row--vs' : ''}`} data-testid="live-row" id={`lv-${v.id}`} data-kind={k.key}>
      {inVisitors && <button type="button" className={`vs-av vs-av--${k.key}`} onClick={locate} aria-label={`${v.who}: show on the map`} data-testid="lv-avatar">
        <VsIcon kind={k.key} /></button>}
      <div className="lv-row__main">
        {inVisitors && <span className="vs-kind">{k.label}</span>}
        <div className="lv-who">
          {typeof v.score === 'number' && band && (
            <span className={`lv-score lv-score--${band}`} data-testid="score" aria-label={`Booking likelihood ${v.score} of 100, ${BAND_WORDS[band].toLowerCase()}`}
              title={`Booking likelihood: ${v.score} of 100`}>{v.score}<span className="lv-score__w" aria-hidden="true">{BAND_WORDS[band]}</span></span>)}
          <b data-testid="live-who">{v.who}</b>{v.known && <span className="ad-b ad-b--dark">{roleLabel(v.roles) ?? 'Known'}</span>}
          {v.label && <span className="ad-b" title={v.label.by ? `Named by ${v.label.by}` : undefined}>{v.label.source === 'renter' && (!v.roles?.length || v.roles.includes('renter')) ? 'Booked' : 'Named'}</span>}
          {v.audience === 'owner' && <span className="ad-b">Owner</span>}
          {portal === 'admin' && personPages(v).map((x) => <Link key={x.href} prefetch={false} className="link small" href={x.href}>{x.label}</Link>)}
          {v.assigned && <span className="ad-b" data-testid="assigned">With {v.assigned.name.split(' ')[0]}</span>}
          {v.last_action && <span className="small muted" suppressHydrationWarning>{ACTION_WORDS[v.last_action.action as keyof typeof ACTION_WORDS]?.replace('Invite to chat', 'Invited') ?? v.last_action.action} by {v.last_action.by}, {agoWords(v.last_action.at)}</span>}
        </div>
        <p className="small"><span className="muted">Now on </span>{v.current_page ?? 'the site'}{v.car ? `: ${v.car}` : ''}{v.booking_number ? ` (${v.booking_number})` : ''}
          {v.others_on_car ? <b className="lv-others"> · {v.others_on_car} other{v.others_on_car === 1 ? '' : 's'} on this car now</b> : null}
          <span className="muted"> · {v.page_views} page{v.page_views === 1 ? '' : 's'} this visit{v.cars_viewed ? `, ${v.cars_viewed} car${v.cars_viewed === 1 ? '' : 's'}` : ''} · visit {v.visit_number}</span></p>
        <p className="small muted">{[v.device, v.city, v.referrer ? `from ${v.referrer}` : null, v.utm_source ? `campaign ${v.utm_source}${v.utm_campaign ? `/${v.utm_campaign}` : ''}` : null, v.from_ad ? 'from an ad' : null].filter(Boolean).join(' · ')} · since {clock(v.started_at)}</p>
        {(v.reasons?.length ?? 0) > 0 && <p className="small lv-why" data-testid="reasons"><span className="muted">Why: </span>{v.reasons!.map((r) => r.why || r.label).join(' · ')}</p>}
        {v.captured && <p className="small" data-testid="live-captured"><span className="muted">Typed into the {v.captured.form}{v.captured.done ? '' : ', not sent'}: </span>
          {[v.captured.name, v.captured.email, v.captured.phone].filter(Boolean).join(', ')}
          {v.captured.email && v.captured.email_confirmed === false && <> <span className="ad-b ad-b--amber">Email not confirmed</span></>}
          {v.captured.renter_id && portal === 'admin' && !v.renter_id && !v.roles?.length && <> <Link prefetch={false} className="link small" href={`/admin/renters/${v.captured.renter_id}`}>Renter page</Link></>}</p>}
        {v.label && (v.label.phone || v.label.email || v.label.note) && (
          <p className="small" data-testid="live-label"><span className="muted">{v.label.by ? `Named by ${v.label.by}` : 'Named'}: </span>
            {[v.label.phone, v.label.email, v.label.note].filter(Boolean).join(' · ')}</p>)}
        {v.signals.length > 0 && <p className="lv-badges">{v.signals.map((s, i) => <SignalBadge key={i} s={s} />)}</p>}
      </div>
      <div className="lv-row__acts">
        {v.chat ? <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${chatHref}?id=${v.chat.id}`}>Open chat {v.chat.number}</Link>
          : <button type="button" className="btn btn--primary btn--sm" onClick={() => setComposing(!composing)} aria-expanded={composing}>Start a chat</button>}
        <button type="button" className="btn btn--quiet btn--sm" onClick={onToggle} aria-expanded={open}>{open ? 'Hide pages' : 'Pages'}</button>
        <button type="button" className="btn btn--quiet btn--sm" onClick={() => setNaming(!naming)} aria-expanded={naming} data-testid="act-name">{v.label ? 'Edit name' : 'Name'}</button>
        {inVisitors && <button type="button" className="btn btn--quiet btn--sm" onClick={locate} data-testid="lv-locate">Show on the map</button>}
      </div>
      {naming && <NameForm v={v} contact={contact} onDone={(m) => { setNaming(false); setMsg(m); onChat(); }} />}
      {sug && v.audience !== 'owner' && (
        <div className="lv-sug" data-testid="suggested">
          <p className="small"><b>Suggested:</b> {ACTION_WORDS[sug.action ?? 'chat']} <span className="muted">({sug.label}{sug.why && sug.why !== sug.label ? `: ${sug.why}` : ''})</span></p>
          {preview && (sug.action === 'chat' || !sug.action) && !v.chat && <p className="lv-sug__msg small">“{preview}”</p>}
          <p className="lv-sug__acts">
            {!v.chat && preview && sug.action !== 'similar' && sug.action !== 'discount' &&
              <button type="button" className="btn btn--primary btn--sm" disabled={busy} onClick={() => void invite(preview, sug.kind)} data-testid="act-invite">Invite to chat with this message</button>}
            {!v.chat && preview && <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setText(preview); setComposing(true); }}>Edit the message</button>}
            {(sug.action === 'similar' || v.signals.some((s) => s.kind === 'unavailable')) && !v.chat &&
              <button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={() => void similar()} data-testid="act-similar">Suggest a similar free car</button>}
            {cfg.discount.can && <button type="button" className={`btn btn--sm ${sug.action === 'discount' ? 'btn--primary' : 'btn--ghost'}`} disabled={busy} onClick={() => void discount()} data-testid="act-discount">Offer a {cfg.discount.percent}% discount code</button>}
            {!v.assigned && <button type="button" className={`btn btn--sm ${sug.action === 'assign' ? 'btn--primary' : 'btn--ghost'}`} disabled={busy} onClick={() => void assign()} data-testid="act-assign">Assign to Sales</button>}
          </p>
        </div>)}
      {composing && (
        <form className="lv-compose" onSubmit={async (e) => {
          e.preventDefault();
          try { const r = await liveDo<{ id: string; number: string }>('live_invite', { session_id: v.id, body: text, kind: sug?.kind }); setMsg(`Chat ${r.number} started. The visitor sees your message.`); setComposing(false); onChat(); }
          catch (er) { setMsg(er instanceof Error ? er.message : 'That did not work'); }
        }}>
          <label className="small" htmlFor={`lvc-${v.id}`}>Your message (the visitor sees it in a bubble)</label>
          <textarea id={`lvc-${v.id}`} className="input" rows={3} maxLength={1000} value={text} placeholder="Hi, I am here if you have a question about this car." onChange={(e) => setText(e.target.value)} />
          <button type="submit" className="btn btn--primary btn--sm">Send</button>
        </form>)}
      {msg && <p className="small" role="status">{msg}</p>}
      {open && (
        <div className="lv-detail">
          {!detail ? <SkeletonLines lines={4} /> : (
            <>
              <p className="small muted">{detail.visits} visit{detail.visits === 1 ? '' : 's'} in all, {detail.visits_7d} this week{detail.email ? ` · ${detail.email}` : ''}</p>
              {v.signals.length > 0 && (
                <ul className="lv-sigdetail">{v.signals.map((s, i) => (
                  <li key={i}><b>{s.label}</b> <span className="muted">{GROUP_WORDS[s.grp ?? ''] ?? ''}{typeof s.weight === 'number' ? `, ${s.weight} points` : ''}</span>{s.why && s.why !== s.label ? `: ${s.why}` : ''}</li>))}</ul>)}
              <ol className="lv-events">{detail.events.filter((e) => e.kind !== 'page_leave').map((e, i) => (
                <li key={i}><span className="muted">{clock(e.at)}</span> {EVENT_WORDS[e.kind] ?? e.kind}{e.kind === 'page_view' ? ` ${e.page ?? e.path}` : ''}{e.car ? `: ${e.car}` : ''}
                  {e.booking_number ? ` (${e.booking_number})` : ''}{e.pickup ? ` ${e.pickup} to ${e.return}` : ''}{e.detail ? `: ${e.detail}` : ''}</li>))}</ol>
            </>)}
        </div>)}
    </li>
  );
}

/** Release 26: a small line icon per kind of visit (the Visitors page's rows); currentColor, no text. */
export function VsIcon({ kind }: { kind: string }) {
  const d: Record<string, string> = {
    chat: 'M4 5h16v11H8l-4 4z',
    form: 'M6 3h9l3 3v15H6zM9 11h6M9 15h6M9 7h3',
    draft: 'M6 3h9l3 3v15H6zM9 11h4M14 15l3-3',
    known: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c1-4 4.5-6 8-6s7 2 8 6',
    visitor: 'M3 12s3.5-6 9-6 9 6 9 6-3.5 6-9 6-9-6-9-6zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
    request: 'M5 4h14v16H5zM8 9h8M8 13h8M8 17h5',
    booking: 'M4 6h16v14H4zM4 10h16M9 3v5M15 3v5',
    signup: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c1-4 4.5-6 8-6M18 15v6M15 18h6',
    contact: 'M4 6h16v12H4zM4 7l8 6 8-6',
    bot: 'M6 9h12v10H6zM12 5v4M9 13h.01M15 13h.01'
  };
  return <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false"><path d={d[kind] ?? d.visitor} /></svg>;
}
