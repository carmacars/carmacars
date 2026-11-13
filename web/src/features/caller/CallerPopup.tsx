'use client';
import './caller.css';
import Link from '@/components/Link';
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { poller } from '@/lib/poll/poll';
import { clock } from '@/features/live/staff';
import { phoneDo, phoneRead } from '@/features/phone/client';
import { RenterNotes } from './RenterNotes';
import { HelperGreeting, HelperTools } from './CallHelper';
import {
  CALLER_POLL_MS, KIND_WORDS, balanceWords, bookingHref, bookingWords, callState, callTimer, callTimerWords, callerTitle, depositWords, pruneDismissed, renterHref,
  splitCalls, visibleCalls, type CallHelp, type CallerLive, type LiveCall, type Portal
} from './model';

// Who is calling (migration 0800): on every page of the Admin portal and of customer service's staff portal, an incoming
// call to the CarmaCars number opens this panel with who it is. A renter: the booking on rent or coming next, what they
// owe, the deposit, what they are waiting on, the last notes (and a box to add one), and their full page. An unknown
// number: Create lead in one tap. The portal asks the database every 10 seconds while in use (lib/poll: once a minute
// when idle, never in a hidden tab); a call stays 3 minutes after it ends, so the note can be written.
// r42 (2670): the panel minimizes to a small chip (the caller's name and the call's timer) and opens again from it. The
// minimize button, Esc and a click anywhere outside the panel minimize it; the cross still closes the call (hidden in
// this browser only). A new call opens by itself. The Call helper (CallHelper.tsx) is inside each call.
const KEY = 'cc-caller-dismissed';
const MIN_KEY = 'cc-caller-min';
const HELP_KEY = 'cc-call-helper-hidden';
function readStore(key: string): Record<string, number> {
  try { const v = JSON.parse(window.localStorage.getItem(key) ?? '{}') as unknown; return v && typeof v === 'object' ? pruneDismissed(v as Record<string, number>, Date.now()) : {}; } catch { return {}; }
}
function writeStore(key: string, d: Record<string, number>) {
  try { window.localStorage.setItem(key, JSON.stringify(d)); } catch { /* private window: it lasts for this page */ }
}
function readHelpHidden(): boolean { try { return window.localStorage.getItem(HELP_KEY) === '1'; } catch { return false; } }

// quiet (r34): an Admin viewing a portal as someone (read only) sees the same empty region, and nothing is read: the live
// read is the Admin's own, refused while viewing
export function CallerPopup({ portal, quiet = false }: { portal: Portal; quiet?: boolean }) {
  const [calls, setCalls] = useState<LiveCall[]>([]);
  const [dismissed, setDismissed] = useState<Record<string, number>>(() => readStore(KEY));
  const [minimized, setMinimized] = useState<Record<string, number>>(() => readStore(MIN_KEY));
  const [help, setHelp] = useState<CallHelp | null>(null);
  const [helpHidden, setHelpHidden] = useState(readHelpHidden);
  const [now, setNow] = useState(0);
  const stopped = useRef(false);
  const askedHelp = useRef(false);
  const region = useRef<HTMLDivElement>(null);
  // where the keyboard goes after a panel became a chip, or a chip a panel
  const focusNext = useRef<string | null>(null);
  const load = useCallback(async () => {
    if (stopped.current) return;
    try { setCalls((await phoneRead<CallerLive>('caller_live')).calls); }
    catch (e) { if (e instanceof Error && /Admins, customer service and Fleet|Admins and customer service|Sign in|Unknown read/.test(e.message)) stopped.current = true; }
  }, []);
  useEffect(() => {
    if (quiet) return;
    const first = setTimeout(() => void load(), 0);
    const due = poller(CALLER_POLL_MS);
    const t = setInterval(() => { if (due()) void load(); }, CALLER_POLL_MS);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [load, quiet]);

  const shown = visibleCalls(calls, dismissed);
  const { open, chips } = splitCalls(shown, minimized);
  const any = shown.length > 0;
  const openIds = open.map((c) => c.id).join(' ');

  // the helper's words are read once, with the first call; without them the pop-up is as before
  useEffect(() => {
    if (!any || askedHelp.current) return;
    askedHelp.current = true;
    phoneRead<CallHelp>('call_helper').then(setHelp).catch(() => { /* no helper: the caller's details still show */ });
  }, [any]);
  // the call's timer, once a second while a call shows
  useEffect(() => {
    if (!any) return;
    const first = setTimeout(() => setNow(Date.now()), 0);
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [any]);

  const close = (id: string) => setDismissed((d) => { const n = { ...d, [id]: Date.now() }; writeStore(KEY, n); return n; });
  const minimize = useCallback((ids: string[], focus: boolean) => {
    if (!ids.length) return;
    if (focus) focusNext.current = `chip-${ids[0]}`;
    setMinimized((m) => { const n = { ...m }; for (const id of ids) n[id] = Date.now(); writeStore(MIN_KEY, n); return n; });
  }, []);
  const reopen = (id: string) => {
    focusNext.current = `min-${id}`;
    setMinimized((m) => { const n = { ...m }; delete n[id]; writeStore(MIN_KEY, n); return n; });
  };
  const toggleHelp = () => setHelpHidden((h) => { try { window.localStorage.setItem(HELP_KEY, h ? '0' : '1'); } catch { /* this page only */ } return !h; });

  // a click outside the panel, or Esc, minimizes it (never closes it)
  useEffect(() => {
    if (!openIds) return;
    const ids = openIds.split(' ');
    const onDown = (e: PointerEvent) => {
      const t = e.target;
      if (t instanceof Node && region.current && !region.current.contains(t)) minimize(ids, false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      const inside = e.target instanceof Node && !!region.current?.contains(e.target);
      // a dialog of the page that is open takes Esc first
      if (!inside && document.querySelector('dialog[open], [aria-modal="true"]')) return;
      minimize(ids, inside);
    };
    document.addEventListener('pointerdown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('pointerdown', onDown); document.removeEventListener('keydown', onKey); };
  }, [openIds, minimize]);
  useEffect(() => {
    const want = focusNext.current;
    if (!want) return;
    focusNext.current = null;
    region.current?.querySelector<HTMLElement>(`[data-focus="${want}"]`)?.focus();
  }, [minimized]);

  const newest = shown[0];
  return (
    <div className="cpop" ref={region} data-testid="caller-popup-region">
      <p className="cpop-sr" role="status" data-testid="caller-announce">{newest ? `${callState(newest)}: ${callerTitle(newest)}` : ''}</p>
      {open.length > 0 && (
        <section className="cpop-panel" aria-label="Who is calling" data-testid="caller-popup">
          {open.map((c) => <CallCard key={c.id} c={c} portal={portal} now={now} help={help} helpHidden={helpHidden} onToggleHelp={toggleHelp}
            onClose={() => close(c.id)} onMinimize={() => minimize([c.id], true)} />)}
        </section>)}
      {chips.length > 0 && (
        <ul className="cpop-chips" aria-label="Calls minimized" data-testid="caller-chips">{chips.map((c) => {
          const timer = now ? callTimer(c, now) : '';
          return (
            <li key={c.id}>
              <button type="button" className={`cpop-chip${c.live ? ' is-live' : ''}`} data-focus={`chip-${c.id}`} onClick={() => reopen(c.id)} data-testid="caller-chip"
                aria-label={`Open the call from ${callerTitle(c)}: ${callState(c)}${timer ? `, ${callTimerWords(timer)}` : ''}`}>
                <span className="cpop-dot" aria-hidden="true" />
                <span className="cpop-chip-name" data-testid="caller-chip-name">{callerTitle(c)}</span>
                <span className="cpop-timer" data-testid="caller-chip-timer" suppressHydrationWarning>{timer}</span>
              </button>
            </li>);
        })}</ul>)}
    </div>
  );
}

function CallCard({ c, portal, now, help, helpHidden, onToggleHelp, onClose, onMinimize }: {
  c: LiveCall; portal: Portal; now: number; help: CallHelp | null; helpHidden: boolean; onToggleHelp: () => void; onClose: () => void; onMinimize: () => void;
}) {
  const r = c.renter;
  const who = callerTitle(c);
  const tools = help && !helpHidden ? <HelperTools help={help} portal={portal} /> : null;
  return (
    <article className={`cpop-card${c.live ? ' is-live' : ''}`} data-testid="caller-card" data-kind={c.kind}>
      <header className="cpop-head">
        <div className="cpop-who">
          <p className="small cpop-state"><span className="cpop-dot" aria-hidden="true" /><span>{callState(c)}</span>
            {now > 0 && <span className="cpop-timer" data-testid="caller-timer" suppressHydrationWarning>{callTimer(c, now)}</span>}</p>
          <h2 className="cpop-title" data-testid="caller-name">{who}</h2>
          <p className="small cpop-sub"><span className="cpop-kind" data-testid="caller-kind">{c.kind === 'renter' ? (r?.booking ? 'Renter with a booking' : 'Renter') : KIND_WORDS[c.kind]}</span>
            <span>{c.display} · <span suppressHydrationWarning>{clock(c.at)}</span>{r?.is_blocked ? ' · Blocked' : ''}{c.lane === 'fleet' ? ' · Fleet: pickup, return or car on rent' : ''}</span></p>
        </div>
        <div className="cpop-tools">
          <button type="button" className="cpop-tool" aria-label={`Minimize the call from ${who}`} title="Minimize (Esc)" onClick={onMinimize} data-focus={`min-${c.id}`} data-testid="caller-minimize">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M3 12h10" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg></button>
          <button type="button" className="cpop-tool" aria-label={`Close the call from ${who}`} title="Close" onClick={onClose} data-testid="caller-close">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="m4 4 8 8M12 4l-8 8" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg></button>
        </div>
      </header>
      {help && <HelperGreeting c={c} help={help} hidden={helpHidden} onToggle={onToggleHelp} portal={portal} />}
      {r ? <RenterBody c={c} portal={portal} tools={tools} /> : c.kind === 'unknown' ? <Unknown c={c} portal={portal} tools={tools} /> : tools}
    </article>
  );
}

function RenterBody({ c, portal, tools }: { c: LiveCall; portal: Portal; tools: ReactNode }) {
  const r = c.renter!;
  const router = useRouter();
  const [err, setErr] = useState('');
  const href = renterHref(portal, r.id);
  // staff outside the renter's window open the record from the call (logged, 24 hours)
  const open = async (e: React.MouseEvent) => {
    if (portal === 'admin') return;
    e.preventDefault();
    try { await phoneDo('caller_open', { call_id: c.id }); router.push(href); } catch (x) { setErr(x instanceof Error ? x.message : 'Could not open the record'); }
  };
  return (
    <div className="cpop-body">
      <dl className="cpop-kv">
        <div><dt>Booking</dt><dd data-testid="caller-booking">{r.booking ? <Link prefetch={false} className="link" href={bookingHref(portal, r.booking.number)}>{bookingWords(r)}</Link> : bookingWords(r)}</dd></div>
        <div><dt>Balance</dt><dd data-testid="caller-balance" className={r.balance.overdue ? 'cpop-warn' : undefined}>{balanceWords(r.balance)}</dd></div>
        <div><dt>Deposit</dt><dd data-testid="caller-deposit">{depositWords(r.deposit)}</dd></div>
        <div><dt>Waiting on</dt><dd data-testid="caller-requests">{r.requests.length ? (
          <ul className="cpop-reqs">{r.requests.slice(0, 4).map((q, i) => <li key={i}>{q.label}{q.booking_number ? ` (${q.booking_number})` : ''}</li>)}</ul>) : 'Nothing open'}</dd></div>
      </dl>
      {tools}
      <RenterNotes key={c.id} renterId={r.id} initial={r.notes} total={r.notes_count} callId={c.id} compact />
      <p className="cpop-foot"><Link prefetch={false} className="btn btn--ghost btn--sm" href={href} onClick={(e) => void open(e)} data-testid="caller-open">Open the renter&apos;s page</Link>
        {err && <span className="small cpop-warn" role="alert">{err}</span>}</p>
    </div>
  );
}

function Unknown({ c, portal, tools }: { c: LiveCall; portal: Portal; tools: ReactNode }) {
  const [state, setState] = useState<'idle' | 'busy' | 'done'>('idle');
  const [err, setErr] = useState('');
  const create = async () => {
    setState('busy'); setErr('');
    try { await phoneDo('phone_create_lead', { id: c.thread_id }); setState('done'); }
    catch (x) { setErr(x instanceof Error ? x.message : 'Not created. Try again.'); setState('idle'); }
  };
  return (
    <div className="cpop-body">
      <p className="small">This number is not matched to a renter, owner or lead.</p>
      <p className="cpop-foot">{state === 'done'
        ? <span role="status" className="small">Lead created. <Link prefetch={false} className="link" href={portal === 'admin' ? '/admin/visitors?view=chat&inbox=phone' : '/staff/visitors?view=chat&inbox=phone'}>Open the conversation</Link></span>
        : <button type="button" className="btn btn--primary btn--sm" onClick={() => void create()} disabled={state === 'busy'} data-testid="caller-create-lead">{state === 'busy' ? 'Creating' : 'Create lead'}</button>}
        {err && <span className="small cpop-warn" role="alert">{err}</span>}</p>
      {tools}
    </div>
  );
}
