'use client';
import './caller.css';
import Link from '@/components/Link';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { poller } from '@/lib/poll/poll';
import { clock } from '@/features/live/staff';
import { phoneDo, phoneRead } from '@/features/phone/client';
import { RenterNotes } from './RenterNotes';
import {
  CALLER_POLL_MS, KIND_WORDS, balanceWords, bookingHref, bookingWords, callState, callerTitle, depositWords, pruneDismissed, renterHref, visibleCalls,
  type CallerLive, type LiveCall, type Portal
} from './model';

// Who is calling (migration 0800): on every page of the Admin portal and of customer service's staff portal, an incoming
// call to the CarmaCars number opens this panel with who it is. A renter: the booking on rent or coming next, what they
// owe, the deposit, what they are waiting on, the last notes (and a box to add one), and their full page. An unknown
// number: Create lead in one tap. The portal asks the database every 10 seconds while in use (lib/poll: once a minute
// when idle, never in a hidden tab); a call stays 3 minutes after it ends, so the note can be written. Closing a call
// hides it in this browser only.
const KEY = 'cc-caller-dismissed';
function readDismissed(): Record<string, number> {
  try { const v = JSON.parse(window.localStorage.getItem(KEY) ?? '{}') as unknown; return v && typeof v === 'object' ? pruneDismissed(v as Record<string, number>, Date.now()) : {}; } catch { return {}; }
}
function writeDismissed(d: Record<string, number>) {
  try { window.localStorage.setItem(KEY, JSON.stringify(d)); } catch { /* private window: closing lasts for this page */ }
}

// quiet (r34): an Admin viewing a portal as someone (read only) sees the same empty region, and nothing is read: the live
// read is the Admin's own, refused while viewing
export function CallerPopup({ portal, quiet = false }: { portal: Portal; quiet?: boolean }) {
  const [calls, setCalls] = useState<LiveCall[]>([]);
  const [dismissed, setDismissed] = useState<Record<string, number>>(readDismissed);
  const stopped = useRef(false);
  const load = useCallback(async () => {
    if (stopped.current) return;
    try { setCalls((await phoneRead<CallerLive>('caller_live')).calls); }
    catch (e) { if (e instanceof Error && /Admins and customer service|Sign in|Unknown read/.test(e.message)) stopped.current = true; }
  }, []);
  useEffect(() => {
    if (quiet) return;
    const first = setTimeout(() => void load(), 0);
    const due = poller(CALLER_POLL_MS);
    const t = setInterval(() => { if (due()) void load(); }, CALLER_POLL_MS);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [load, quiet]);
  const close = (id: string) => setDismissed((d) => { const n = { ...d, [id]: Date.now() }; writeDismissed(n); return n; });
  const shown = visibleCalls(calls, dismissed);
  return (
    <div className="cpop" aria-live="polite" data-testid="caller-popup-region">
      {shown.length > 0 && (
        <section className="cpop-panel" aria-label="Who is calling" data-testid="caller-popup">
          {shown.map((c) => <CallCard key={c.id} c={c} portal={portal} onClose={() => close(c.id)} />)}
        </section>)}
    </div>
  );
}

function CallCard({ c, portal, onClose }: { c: LiveCall; portal: Portal; onClose: () => void }) {
  const r = c.renter;
  return (
    <article className={`cpop-card${c.live ? ' is-live' : ''}`} data-testid="caller-card" data-kind={c.kind}>
      <header className="cpop-head">
        <div>
          <p className="small cpop-state"><span className="cpop-dot" aria-hidden="true" />{callState(c)} · <span suppressHydrationWarning>{clock(c.at)}</span></p>
          <h2 className="cpop-title" data-testid="caller-name">{callerTitle(c)}</h2>
          <p className="small muted">{c.display}{c.kind !== 'unknown' && c.kind !== 'renter' ? ` · ${KIND_WORDS[c.kind]}` : ''}{r?.is_blocked ? ' · Blocked' : ''}</p>
        </div>
        <button type="button" className="cpop-x" aria-label={`Close the call from ${callerTitle(c)}`} onClick={onClose} data-testid="caller-close">×</button>
      </header>
      {r ? <RenterBody c={c} portal={portal} /> : c.kind === 'unknown' ? <Unknown c={c} portal={portal} /> : null}
    </article>
  );
}

function RenterBody({ c, portal }: { c: LiveCall; portal: Portal }) {
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
      <RenterNotes key={c.id} renterId={r.id} initial={r.notes} total={r.notes_count} callId={c.id} compact />
      <p className="cpop-foot"><Link prefetch={false} className="btn btn--ghost btn--sm" href={href} onClick={(e) => void open(e)} data-testid="caller-open">Open the renter&apos;s page</Link>
        {err && <span className="small cpop-warn" role="alert">{err}</span>}</p>
    </div>
  );
}

function Unknown({ c, portal }: { c: LiveCall; portal: Portal }) {
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
    </div>
  );
}
