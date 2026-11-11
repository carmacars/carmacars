'use client';
import './phone.css';
import Link from '@/components/Link';
import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { QUO_DESKTOP_KEY, QUO_WEB, callPlan, e164, isHandheld, prettyNumber, quoMessage, smsHref, telHref } from './quo-links';

// The Call and Text buttons of every staff page (r27 consolidation, migration 0500; the owner on November 2, 2026: "Call and
// Text through Quo"). Text opens a composer here that sends from the CarmaCars number through Quo, and the text is kept in
// the person's conversation (Texts and calls). Call opens Quo with the number: the Quo app on a phone, on a computer the Quo
// web app (the number copied for its dialer) or, when chosen on this computer, the Quo desktop app; every call is logged
// on the conversation. When Quo is off (Program settings, or Phone and texts off) the buttons are the device's own phone and
// messages links, as before. Without JavaScript they are those links too.

// r35 (0970): twilio: the Call button rings the staff member's own cell, then the customer (twilio_why: why not, shown on the
// Quo fallback); can_reveal: an Admin may reveal a number masked for Sales (audited)
type Cfg = { quo: boolean; from: string | null; any_number?: boolean; twilio?: boolean; twilio_why?: string | null; can_reveal?: boolean };
/** A number masked for Sales ("(647) •••-••00", migration 0970): shown as it is, called and texted through the platform only. */
export const isMasked = (s: string | null | undefined): boolean => !!s && s.includes('\u2022');
let cfgP: Promise<Cfg> | null = null;
let cfgV: Cfg | null = null;
function loadCfg(): Promise<Cfg> {
  cfgP ??= fetch('/api/staff/phone?what=phone_buttons', { cache: 'no-store', credentials: 'same-origin' })
    .then(async (r) => (r.ok ? ((await r.json()) as Cfg) : { quo: false, from: null }))
    .catch(() => ({ quo: false, from: null }))
    .then((c) => { cfgV = c; return c; });
  return cfgP;
}
function useCfg(): Cfg | null {
  const [c, setC] = useState<Cfg | null>(cfgV);
  useEffect(() => { let live = true; void loadCfg().then((x) => { if (live) setC(x); }); return () => { live = false; }; }, []);
  return c;
}
const readDesktop = () => { try { return localStorage.getItem(QUO_DESKTOP_KEY); } catch { return null; } };
const writeDesktop = (v: 'app' | 'web') => { try { localStorage.setItem(QUO_DESKTOP_KEY, v); } catch { /* this visit only */ } };

/** What a person reads when the send did not finish (r27b: the raw "error code: 504" of a busy server is never shown). */
export const SLOW_SEND = 'The server was too slow to confirm the text. It was not sent twice: press Send again and we check first.';
export function sendProblem(status: number, error: string | undefined): string {
  if (error && !/^error code:|^<!doctype|^<html|gave up|statement timeout|did not answer in time/i.test(error.trim())) return error;
  if (status === 0 || status === 408 || status === 429 || status >= 500 || (error && /error code: 5|gave up|timeout|did not answer/i.test(error))) return SLOW_SEND;
  return error || 'Something went wrong';
}

async function post(action: string, p: Record<string, unknown>, timeoutMs = 25_000): Promise<Record<string, unknown> & { ok?: boolean; error?: string }> {
  let r: Response;
  try {
    // r27b: a bounded wait (the server gives up on its own calls before this), so the dialog never hangs on "Sending"
    r = await fetch('/api/staff/phone', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', keepalive: true,
      body: JSON.stringify({ action, ...p }), signal: AbortSignal.timeout(timeoutMs) });
  } catch { throw new Error(sendProblem(0, undefined)); }
  const j = (await r.json().catch(() => ({}))) as Record<string, unknown> & { ok?: boolean; error?: string };
  if (!r.ok) throw new Error(sendProblem(r.status, j.error));
  return j;
}
const newKey = () => { try { return crypto.randomUUID(); } catch { return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`; } };

const Phone = () => <svg viewBox="0 0 20 20" aria-hidden="true" className="qb-ic"><path d="M6.6 2.5 4.4 3.1c-.8.2-1.3 1-1.2 1.8.6 6.1 5.7 11.2 11.8 11.8.8.1 1.6-.4 1.8-1.2l.6-2.2-3.4-1.5-1.5 1.6a9 9 0 0 1-4.6-4.6l1.6-1.5z" /></svg>;
const Bubble = () => <svg viewBox="0 0 20 20" aria-hidden="true" className="qb-ic"><path d="M3.5 4.5h13v9h-7l-4 3v-3h-2z" /></svg>;

export interface ContactProps {
  phone: string | null | undefined; name?: string | null; booking?: string | null;
  /** 'buttons' (Call and Text, ghost), 'icons' (round icons, the Now view and the map cards), 'link' (the number as a link that calls, a Text icon beside it) */
  look?: 'buttons' | 'icons' | 'link';
  /** where the person's conversation opens (Admin, customer service and Sales: the Visitors page's Texts and calls) */
  inbox?: string | null;
  /** only one of the two */ only?: 'call' | 'text';
  testId?: string; className?: string; children?: ReactNode;
  /** the buttons' own class (the field pages' big buttons) */ btnClass?: string;
}

/** Call and Text for one person. Nothing shows for a number we cannot call. */
export function ContactButtons(props: ContactProps) {
  return isMasked(props.phone) ? <MaskedButtons {...props} /> : <PlainButtons {...props} />;
}

type CallState = { busy?: boolean; ok?: boolean; message?: string; calling?: string };
async function twilioCall(number: string, booking: string | null | undefined, name: string | null | undefined): Promise<CallState> {
  try {
    const r = await post('phone_call', { number, ...(booking ? { booking_number: booking } : {}), ...(name ? { name } : {}) });
    return r.ok ? { ok: true, calling: typeof r.calling === 'string' ? r.calling : undefined } : { ok: false, message: typeof r.message === 'string' ? r.message : 'The call did not start' };
  } catch (e) { return { ok: false, message: e instanceof Error ? e.message : 'The call did not start' }; }
}

/** Sales (0970): the masked number, Call and Text through the platform (no tel: or sms: link, nothing to copy). */
function MaskedButtons({ phone, name, booking, look = 'buttons', inbox, only, testId = 'contact', className, children, btnClass = 'btn btn--ghost btn--sm' }: ContactProps) {
  const m = phone!;
  const cfg = useCfg();
  const [sheet, setSheet] = useState<null | 'text' | 'call'>(null);
  const [call, setCall] = useState<CallState>({});
  const [shown, setShown] = useState<string | null>(null);
  const who = name?.trim() || m;
  const onCall = async () => {
    setSheet('call');
    if (!cfg?.twilio) { setCall({ ok: false, message: `${cfg?.twilio_why ?? 'Calling from the site is not set up yet.'} The number is hidden for Sales: ask customer service or an Admin to call.` }); return; }
    setCall({ busy: true });
    setCall(await twilioCall(m, booking, name));
  };
  const reveal = async () => {
    const q = new URLSearchParams({ what: 'phone_reveal', masked: m, ...(booking ? { booking } : {}), ...(name ? { name } : {}) });
    const r = await fetch(`/api/staff/phone?${q}`, { cache: 'no-store', credentials: 'same-origin' }).then((x) => x.json()).catch(() => null) as { display?: string; error?: string } | null;
    setShown(r?.display ?? r?.error ?? 'Not revealed');
  };
  return (
    <span className={`qb qb--${look}${className ? ` ${className}` : ''}`} data-testid={`${testId}-masked`}>
      <span className="qb-masked" title="Hidden for Sales: call or text from here">{shown ?? (look === 'link' ? m : null)}</span>
      {only !== 'text' && <button type="button" className={look === 'buttons' ? `${btnClass} qb-btn` : 'qb-icon'} onClick={() => void onCall()} aria-label={`Call ${who}`} data-testid={`${testId}-call`}><Phone />{look === 'buttons' ? (children ?? 'Call') : null}</button>}
      {only !== 'call' && <button type="button" className={look === 'buttons' ? 'btn btn--quiet btn--sm qb-btn qb-btn--text' : 'qb-icon'} onClick={() => setSheet('text')} aria-label={`Text ${who}`} data-testid={`${testId}-text`}><Bubble />{look === 'buttons' ? 'Text' : null}</button>}
      {cfg?.can_reveal && !shown && <button type="button" className="btn btn--quiet btn--sm" onClick={() => void reveal()} data-testid={`${testId}-reveal`}>Reveal</button>}
      {sheet === 'text' && <Composer n={m} who={who} booking={booking} from={cfg?.from ?? null} inbox={inbox} onClose={() => setSheet(null)} testId={testId} />}
      {sheet === 'call' && <TwilioSheet who={who} state={call} onClose={() => setSheet(null)} testId={testId} />}
    </span>
  );
}

function TwilioSheet({ who, state, onClose, testId, n }: { who: string; state: CallState; onClose: () => void; testId: string; n?: string }) {
  return (
    <Sheet title={`Call ${who}`} onClose={onClose} testId={`${testId}-call-sheet`}>
      {state.busy ? <p className="small" role="status">Starting the call...</p>
        : state.ok ? <p className="small" role="status" data-testid="twilio-ringing"><b>Your phone{state.calling ? ` (${state.calling})` : ''} rings now.</b> Answer it and we connect {who}. They see the CarmaCars number. The call is noted on their history.</p>
          : <p className="alert alert--warn small" role="alert" data-testid="twilio-why"><span>{state.message}</span></p>}
      <p className="qb-acts">{n && !state.ok && !state.busy && <a className="btn btn--ghost btn--sm" href={QUO_WEB} target="carmacars-quo" rel="noopener">Open the Quo web app</a>}
        <button type="button" className="btn btn--primary btn--sm" onClick={onClose}>Done</button></p>
    </Sheet>
  );
}

function PlainButtons({ phone, name, booking, look = 'buttons', inbox, only, testId = 'contact', className, children, btnClass = 'btn btn--ghost btn--sm' }: ContactProps) {
  const n = e164(phone);
  const cfg = useCfg();
  const [sheet, setSheet] = useState<null | 'text' | 'call' | 'twilio'>(null);
  const [callSt, setCallSt] = useState<CallState>({});
  if (!n) return phone ? <span className={className}>{phone}</span> : null;
  const who = name?.trim() || prettyNumber(n);
  const quo = !!cfg?.quo;

  const onCall = (e: React.MouseEvent) => {
    // r35 (0970): through Twilio when it is set up: the staff member's own cell rings, then the customer
    if (cfg?.twilio) {
      e.preventDefault();
      setSheet('twilio'); setCallSt({ busy: true });
      void twilioCall(n, booking, name).then(setCallSt);
      return;
    }
    if (!cfg?.quo) return; // the tel: link does it
    e.preventDefault();
    void post('phone_call_log', { number: n, ...(booking ? { booking_number: booking } : {}) }).catch(() => undefined);
    const plan = callPlan(n, { quo: true, from: cfg.from, ua: navigator.userAgent, desktop: readDesktop() });
    if (plan.kind === 'quo-web') {
      window.open(plan.href, 'carmacars-quo', 'noopener');
      void navigator.clipboard?.writeText(n).catch(() => undefined);
      setSheet('call');
      return;
    }
    window.location.assign(plan.href);
    // a phone without the Quo app stays on this page: offer the web app and the phone's own dialer
    if (plan.kind === 'quo-app') setTimeout(() => { if (document.visibilityState === 'visible') setSheet('call'); }, 1600);
  };
  const onText = (e: React.MouseEvent) => {
    if (!cfg?.quo) return; // the sms: link does it
    e.preventDefault();
    setSheet('text');
  };

  const call = only === 'text' ? null : look === 'icons'
    ? <a className="qb-icon" href={telHref(n)} onClick={onCall} aria-label={`Call ${who}`} title={`Call ${prettyNumber(n)}${quo ? ' in Quo' : ''}`} data-testid={`${testId}-call`}><Phone /></a>
    : look === 'link'
      ? <a className="link" href={telHref(n)} onClick={onCall} title={`Call ${who}${quo ? ' in Quo' : ''}`} data-testid={testId}>{children ?? prettyNumber(n)}</a>
      : <a className={`${btnClass} qb-btn`} href={telHref(n)} onClick={onCall} data-testid={`${testId}-call`}><Phone />{children ?? 'Call'}</a>;
  const text = only === 'call' ? null : look === 'buttons'
    ? <a className="btn btn--quiet btn--sm qb-btn qb-btn--text" href={smsHref(n)} onClick={onText} data-testid={`${testId}-text`}><Bubble />Text</a>
    : <a className="qb-icon" href={smsHref(n)} onClick={onText} aria-label={`Text ${who}`} title={`Text ${prettyNumber(n)}`} data-testid={`${testId}-text`}><Bubble /></a>;
  return (
    <span className={`qb qb--${look}${className ? ` ${className}` : ''}`}>
      {call}{text}
      {sheet === 'text' && <Composer n={n} who={who} booking={booking} from={cfg?.from ?? null} inbox={inbox} onClose={() => setSheet(null)} testId={testId} />}
      {sheet === 'call' && <CallSheet n={n} who={who} why={cfg?.twilio_why ?? null} onClose={() => setSheet(null)} testId={testId} />}
      {sheet === 'twilio' && <TwilioSheet n={n} who={who} state={callSt} onClose={() => setSheet(null)} testId={testId} />}
    </span>
  );
}

function Sheet({ title, onClose, children, testId }: { title: string; onClose: () => void; children: ReactNode; testId: string }) {
  const ref = useRef<HTMLDialogElement>(null);
  const id = useId();
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) { try { d.showModal(); } catch { d.setAttribute('open', ''); } }
    // the text box (composer) or the main button (call), not the close button
    d?.querySelector<HTMLElement>('textarea, .btn--primary')?.focus();
    return () => { try { d?.close(); } catch { /* gone */ } };
  }, []);
  return (
    <dialog ref={ref} className="qb-sheet" aria-labelledby={`${id}-t`} onClose={onClose} onCancel={onClose} data-testid={testId}
      onClick={(e) => { if (e.target === ref.current) onClose(); }}>
      <div className="qb-sheet__in">
        <div className="qb-sheet__head"><h2 className="qb-sheet__t" id={`${id}-t`}>{title}</h2>
          <button type="button" className="qb-sheet__x" onClick={onClose} aria-label="Close">×</button></div>
        {children}
      </div>
    </dialog>
  );
}

function Composer({ n, who, booking, from, inbox, onClose, testId }: { n: string; who: string; booking?: string | null; from: string | null; inbox?: string | null; onClose: () => void; testId: string }) {
  const [body, setBody] = useState('');
  const [state, setState] = useState<{ busy?: boolean; err?: string; sent?: string | null; note?: string }>({});
  // r27b: one key for this text, sent with every try: the database sends it once however often Send is pressed
  const key = useRef<string>(newKey());
  const send = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!body.trim() || state.busy) return;
    setState({ busy: true });
    try {
      const r = await post('phone_compose', { number: n, body, key: key.current, ...(booking ? { booking_number: booking } : {}) });
      if (r.ok === false) throw new Error(r.error ?? 'Not sent');
      setState({ sent: typeof r.thread_id === 'string' ? r.thread_id : null, note: typeof r.note === 'string' ? r.note : undefined });
    } catch (x) { setState({ err: x instanceof Error ? x.message : 'Not sent' }); }
  };
  const left = 1600 - body.length;
  return (
    <Sheet title={`Text ${who}`} onClose={onClose} testId={`${testId}-composer`}>
      {state.sent !== undefined ? (
        <div className="qb-done" role="status" data-testid="quo-sent">
          <p><b>Sent</b> from the CarmaCars number{from ? ` (${prettyNumber(from)})` : ''}. It is in {who}&apos;s conversation.{state.note ? ` ${state.note}` : ''}</p>
          <p className="qb-acts">{inbox && state.sent && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${inbox}${inbox.includes('?') ? '&' : '?'}inbox=phone&id=${state.sent}`}>Open the conversation</Link>}
            <button type="button" className="btn btn--primary btn--sm" onClick={onClose}>Done</button></p>
        </div>
      ) : (
        <form onSubmit={send} className="qb-form">
          <p className="small muted qb-to">To {prettyNumber(n)}, from the CarmaCars number{from ? ` ${prettyNumber(from)}` : ''}{booking ? `, about ${booking}` : ''}.</p>
          <label className="vh" htmlFor={`${testId}-body`}>The text</label>
          <textarea id={`${testId}-body`} className="input qb-body" rows={4} maxLength={1600} value={body} onChange={(e) => setBody(e.target.value)} autoFocus
            placeholder="Write the text. Sign it CarmaCars." data-testid="quo-body" />
          <p className="qb-acts">
            <span className="small muted" aria-live="polite">{left < 200 ? `${left} characters left` : ''}</span>
            {!isMasked(n) && isHandheld(typeof navigator === 'undefined' ? '' : navigator.userAgent) && <a className="btn btn--quiet btn--sm" href={quoMessage(n, from, body || undefined)}>Open in the Quo app</a>}
            <button type="submit" className="btn btn--primary btn--sm" disabled={!body.trim() || state.busy} data-testid="quo-send">{state.busy ? 'Sending' : 'Send'}</button>
          </p>
          {state.err && <p className="alert alert--error small" role="alert"><span>{state.err}</span></p>}
        </form>
      )}
    </Sheet>
  );
}

function CallSheet({ n, who, why, onClose, testId }: { n: string; who: string; why?: string | null; onClose: () => void; testId: string }) {
  const [app, setApp] = useState(() => readDesktop() === 'app');
  const handheld = typeof navigator !== 'undefined' && isHandheld(navigator.userAgent);
  return (
    <Sheet title={`Call ${who}`} onClose={onClose} testId={`${testId}-call-sheet`}>
      <p className="qb-num" data-testid="quo-call-number">{prettyNumber(n)}</p>
      {why && <p className="small muted" data-testid="quo-call-why">Calling through Quo: {why}</p>}
      {handheld
        ? <p className="small">The Quo app did not open. Call from the Quo web app, or from this phone.</p>
        : <p className="small">Quo opened in a new tab and the number is copied. In Quo, open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. The call is noted on the conversation.</p>}
      <p className="qb-acts">
        <a className="btn btn--primary btn--sm" href={QUO_WEB} target="carmacars-quo" rel="noopener">Open the Quo web app</a>
        <a className="btn btn--ghost btn--sm" href={telHref(n)}>{handheld ? 'Use this phone' : 'Use this computer’s phone app'}</a>
      </p>
      {!handheld && <label className="qb-pref small"><input type="checkbox" checked={app} onChange={(e) => { setApp(e.target.checked); writeDesktop(e.target.checked ? 'app' : 'web'); }} data-testid="quo-desktop-pref" />
        <span>On this computer, call with the Quo desktop app<span className="muted"> (when it is the computer&apos;s calling app)</span></span></label>}
    </Sheet>
  );
}
