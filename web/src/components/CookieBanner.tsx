'use client';
import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import type { CookieWording } from '@/lib/types';
import { browserRpc } from '@/lib/browser-rpc';
import { toast } from '@/lib/toast';

// Cookie consent (migration 0025): the wording and its version come from site content; the answer
// is kept in a first-party cookie for this browser and stored with public.record_cookie_choice.
// A new wording version asks again. "Cookie choices" in the footer reopens the preferences.
const CHOICE = 'cc_cookie_choice';
const VISITOR = 'cc_vid';
type Choice = { version: string; choice: 'accept_all' | 'necessary_only' | 'custom' | 'implied'; analytics: boolean };
/** Where the visitor is browsing from (the Worker's cc_geo cookie, e.g. CA-ON); null when unknown. */
const geo = () => { const g = readCookie('cc_geo'); return g && /^[A-Z]{2}(-[A-Z0-9]{1,3})?$/.test(g) ? g : null; };
/** Notice and opt out (0075) for the regions the wording lists; everyone else, and an unknown location, is asked first. */
export function noticeOnly(w: Pick<CookieWording, 'implied_regions' | 'implied_exceptions' | 'notice'>, g: string | null): boolean {
  if (!g || !w.notice) return false;
  const country = g.split('-')[0]!;
  if ((w.implied_exceptions ?? []).some((x) => x === g || x === country)) return false;
  return (w.implied_regions ?? []).some((x) => x === g || x === country);
}

const readCookie = (n: string) => document.cookie.split('; ').find((c) => c.startsWith(n + '='))?.split('=').slice(1).join('=');
const writeCookie = (n: string, v: string) => { document.cookie = `${n}=${v}; path=/; max-age=${60 * 60 * 24 * 365}; samesite=lax${location.protocol === 'https:' ? '; secure' : ''}`; };
function current(version: string): Choice | null {
  try { const v = JSON.parse(decodeURIComponent(readCookie(CHOICE) ?? '')) as Choice; return v.version === version ? v : null; } catch { return null; }
}
function visitorId(): string {
  let v = readCookie(VISITOR);
  if (!v) { v = crypto.randomUUID(); writeCookie(VISITOR, v); }
  return v;
}

export function CookiePrefsButton() {
  return <button type="button" className="footer-btn" onClick={(e) => window.dispatchEvent(new CustomEvent('cc:cookie-prefs', { detail: e.currentTarget }))}>Cookie choices</button>;
}

export function CookieBanner({ w }: { w: CookieWording | null }) {
  const [show, setShow] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null);
  const opener = useRef<HTMLElement | null>(null);
  const [analytics, setAnalytics] = useState(false);
  const [notice, setNotice] = useState(false);

  useEffect(() => {
    if (!w) return;
    const have = current(w.version);
    // the stored choice lives in a cookie this static page can only read after it loads
    if (!have && noticeOnly(w, geo())) {
      // notice and opt out: analytics on now, recorded with the region; the notice fades after a few seconds
      const v: Choice = { version: w.version, choice: 'implied', analytics: true };
      writeCookie(CHOICE, encodeURIComponent(JSON.stringify(v)));
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setAnalytics(true); setNotice(true); setShow(true);
      window.dispatchEvent(new CustomEvent('cc:consent', { detail: { analytics: true } }));
      browserRpc('record_cookie_notice', { p_visitor_id: visitorId(), p_wording_version: w.version, p_region: geo(), p_user_agent: navigator.userAgent.slice(0, 300) }).catch(() => { /* kept in the browser */ });
    } else if (!have) setShow(true); else setAnalytics(have.analytics);
    const open = (e: Event) => { opener.current = (e as CustomEvent<HTMLElement>).detail ?? null; setAnalytics(current(w.version)?.analytics ?? false); dialog.current?.showModal(); };
    window.addEventListener('cc:cookie-prefs', open);
    return () => window.removeEventListener('cc:cookie-prefs', open);
  }, [w]);

  useEffect(() => {
    if (!notice || !show) return;
    const t = setTimeout(() => setShow(false), Math.max(4, w?.notice_seconds ?? 10) * 1000);
    return () => clearTimeout(t);
  }, [notice, show, w]);

  if (!w) return null;
  const save = (choice: Choice['choice'], on: boolean) => {
    const v: Choice = { version: w.version, choice, analytics: on };
    writeCookie(CHOICE, encodeURIComponent(JSON.stringify(v)));
    setShow(false); dialog.current?.close();
    // the site's own beacon (Live visitors, 0060) follows the choice at once
    window.dispatchEvent(new CustomEvent('cc:consent', { detail: { analytics: on } }));
    browserRpc('record_cookie_choice', { p_visitor_id: visitorId(), p_choice: choice, p_wording_version: w.version, p_analytics: on, p_user_agent: navigator.userAgent.slice(0, 300) })
      .catch(() => { /* the choice is kept in the browser; the record is retried on the next change */ });
    toast(on ? 'Saved. Analytics cookies are on.' : 'Saved. Only necessary cookies are used.');
  };

  return (
    <>
      {show && notice && (
        <section className="cookie cookie--compact cookie--notice on-dark" aria-labelledby="ck-n" data-testid="cookie-notice">
          <h2 className="vh" id="ck-n">{w.title}</h2>
          <p className="cookie__line small">{w.notice} <Link prefetch={false} className="link" href="/privacy#cookies-and-analytics">How we use cookies</Link></p>
          <p className="cookie__notice-btns">
            <button type="button" className="btn btn--primary btn--sm" onClick={() => setShow(false)} data-testid="cookie-ok">{w.ok ?? 'OK'}</button>
            <button type="button" className="cookie__link" onClick={() => save('necessary_only', false)} data-testid="cookie-optout">{w.optout ?? w.necessary}</button>
          </p>
        </section>
      )}
      {show && !notice && (
        <section className="cookie cookie--compact on-dark" aria-labelledby="ck-t" data-testid="cookie-banner">
          <h2 className="vh" id="ck-t">{w.title}</h2>
          <p className="cookie__line small">{w.text} <Link prefetch={false} className="link" href="/privacy#cookies-and-analytics">How we use cookies</Link></p>
          <button type="button" className="btn btn--primary cookie__accept" onClick={() => save('accept_all', true)} data-testid="cookie-accept">{w.accept}</button>
          <p className="cookie__more small">
            <button type="button" className="cookie__link" onClick={() => save('necessary_only', false)} data-testid="cookie-necessary">{w.necessary}</button>
            <span aria-hidden="true"> · </span>
            <button type="button" className="cookie__link" onClick={(e) => { opener.current = e.currentTarget; dialog.current?.showModal(); }}>{w.prefs}</button>
          </p>
        </section>
      )}
      <dialog className="modal" id="cookie-prefs" aria-labelledby="ck-pt" ref={dialog}
        onClick={(e) => { if (e.target === dialog.current) dialog.current?.close(); }}
        onClose={() => { if (opener.current && document.contains(opener.current)) opener.current.focus(); }}>
        <div className="modal__head"><h2 className="d3" id="ck-pt">{w.title}</h2><button type="button" className="modal__close" aria-label="Close" onClick={() => dialog.current?.close()}>×</button></div>
        <div className="modal__body stack">
          <p className="small">{w.text}</p>
          {w.groups.map((g) => (
            <label key={g.code} className="check cookie__opt">
              <input type="checkbox" name={g.code} checked={g.always ? true : analytics} disabled={g.always} onChange={(e) => setAnalytics(e.target.checked)} />
              <span><b>{g.name}</b><br /><span className="small muted">{g.text}</span></span>
            </label>
          ))}
        </div>
        <div className="modal__foot">
          <button type="button" className="btn btn--ghost" onClick={() => save('necessary_only', false)}>{w.necessary}</button>
          <button type="button" className="btn btn--primary" onClick={() => save('custom', analytics)}>{w.save}</button>
        </div>
      </dialog>
    </>
  );
}
