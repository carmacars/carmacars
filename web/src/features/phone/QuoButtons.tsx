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

type Cfg = { quo: boolean; from: string | null; any_number?: boolean };
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

async function post(action: string, p: Record<string, unknown>): Promise<Record<string, unknown> & { ok?: boolean; error?: string }> {
  const r = await fetch('/api/staff/phone', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', keepalive: true, body: JSON.stringify({ action, ...p }) });
  const j = (await r.json().catch(() => ({}))) as Record<string, unknown> & { ok?: boolean; error?: string };
  if (!r.ok) throw new Error(j.error ?? 'Something went wrong');
  return j;
}

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
export function ContactButtons({ phone, name, booking, look = 'buttons', inbox, only, testId = 'contact', className, children, btnClass = 'btn btn--ghost btn--sm' }: ContactProps) {
  const n = e164(phone);
  const cfg = useCfg();
  const [sheet, setSheet] = useState<null | 'text' | 'call'>(null);
  if (!n) return phone ? <span className={className}>{phone}</span> : null;
  const who = name?.trim() || prettyNumber(n);
  const quo = !!cfg?.quo;

  const onCall = (e: React.MouseEvent) => {
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
    window.location.href = plan.href;
    // a phone without the Quo app stays on this page: offer the web app and the phone's own dialer
    if (plan.kind === 'quo-app') setTimeout(() => { if (document.visibilityState === 'visible') setSheet('call'); }, 1600);
  };
  const onText = (e: React.MouseEvent) => {
    if (!cfg?.quo) return; // the sms: link does it
    e.preventDefault();
    setSheet('text');
  };

  const call = only === 'text' ? null : look === 'icons'
    ? <a className="qb-icon" href={telHref(n)} onClick={onCall} aria-label={`Call ${who}${quo ? ' in Quo' : ''}`} title={`Call ${prettyNumber(n)}`} data-testid={`${testId}-call`}><Phone /></a>
    : look === 'link'
      ? <a className="link" href={telHref(n)} onClick={onCall} aria-label={`Call ${who}${quo ? ' in Quo' : ''}`} data-testid={`${testId}-call`}>{children ?? prettyNumber(n)}</a>
      : <a className={`${btnClass} qb-btn`} href={telHref(n)} onClick={onCall} data-testid={`${testId}-call`}><Phone />{children ?? 'Call'}</a>;
  const text = only === 'call' ? null : look === 'buttons'
    ? <a className={`${btnClass} qb-btn`} href={smsHref(n)} onClick={onText} data-testid={`${testId}-text`}><Bubble />Text</a>
    : <a className="qb-icon" href={smsHref(n)} onClick={onText} aria-label={`Text ${who}`} title={`Text ${prettyNumber(n)}`} data-testid={`${testId}-text`}><Bubble /></a>;
  return (
    <span className={`qb qb--${look}${className ? ` ${className}` : ''}`}>
      {call}{text}
      {sheet === 'text' && <Composer n={n} who={who} booking={booking} from={cfg?.from ?? null} inbox={inbox} onClose={() => setSheet(null)} testId={testId} />}
      {sheet === 'call' && <CallSheet n={n} who={who} onClose={() => setSheet(null)} testId={testId} />}
    </span>
  );
}

function Sheet({ title, onClose, children, testId }: { title: string; onClose: () => void; children: ReactNode; testId: string }) {
  const ref = useRef<HTMLDialogElement>(null);
  const id = useId();
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) { try { d.showModal(); } catch { d.setAttribute('open', ''); } }
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
  const [state, setState] = useState<{ busy?: boolean; err?: string; sent?: string | null }>({});
  const send = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!body.trim() || state.busy) return;
    setState({ busy: true });
    try {
      const r = await post('phone_compose', { number: n, body, ...(booking ? { booking_number: booking } : {}) });
      if (r.ok === false) throw new Error(r.error ?? 'Not sent');
      setState({ sent: typeof r.thread_id === 'string' ? r.thread_id : null });
    } catch (x) { setState({ err: x instanceof Error ? x.message : 'Not sent' }); }
  };
  const left = 1600 - body.length;
  return (
    <Sheet title={`Text ${who}`} onClose={onClose} testId={`${testId}-composer`}>
      {state.sent !== undefined ? (
        <div className="qb-done" role="status" data-testid="quo-sent">
          <p><b>Sent</b> from the CarmaCars number{from ? ` (${prettyNumber(from)})` : ''}. It is in {who}&apos;s conversation.</p>
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
            {isHandheld(typeof navigator === 'undefined' ? '' : navigator.userAgent) && <a className="btn btn--quiet btn--sm" href={quoMessage(n, from, body || undefined)}>Open in the Quo app</a>}
            <button type="submit" className="btn btn--primary btn--sm" disabled={!body.trim() || state.busy} data-testid="quo-send">{state.busy ? 'Sending' : 'Send'}</button>
          </p>
          {state.err && <p className="alert alert--error small" role="alert"><span>{state.err}</span></p>}
        </form>
      )}
    </Sheet>
  );
}

function CallSheet({ n, who, onClose, testId }: { n: string; who: string; onClose: () => void; testId: string }) {
  const [app, setApp] = useState(() => readDesktop() === 'app');
  const handheld = typeof navigator !== 'undefined' && isHandheld(navigator.userAgent);
  return (
    <Sheet title={`Call ${who}`} onClose={onClose} testId={`${testId}-call-sheet`}>
      <p className="qb-num" data-testid="quo-call-number">{prettyNumber(n)}</p>
      {handheld
        ? <p className="small">The Quo app did not open. Call from the Quo web app, or from this phone.</p>
        : <p className="small">Quo opened in a new tab and the number is copied. In Quo, open the dialer (Alt+C, or Ctrl+C on a Mac) and paste it. The call is noted on the conversation.</p>}
      <p className="qb-acts">
        <a className="btn btn--primary btn--sm" href={QUO_WEB} target="carmacars-quo" rel="noopener">Open the Quo web app</a>
        <a className="btn btn--ghost btn--sm" href={telHref(n)}>{handheld ? 'Use this phone' : 'Use this computer’s phone app'}</a>
      </p>
      {!handheld && <label className="qb-pref small"><input type="checkbox" checked={app} onChange={(e) => { setApp(e.target.checked); writeDesktop(e.target.checked ? 'app' : 'web'); }} data-testid="quo-desktop-pref" />
        On this computer, call with the Quo desktop app (set as the default calling app)</label>}
    </Sheet>
  );
}
