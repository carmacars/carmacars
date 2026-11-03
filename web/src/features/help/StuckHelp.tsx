'use client';
import '@/styles/stuck.css';
import { useCallback, useEffect, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';
import { helpFor, type HelpPortal } from './routes';
import { StuckDetector, pageName, stuckOptions, type StuckTrigger } from './stuck';

// "Stuck?" help in every portal (migration 0510): when someone works on a page without getting anywhere (stuck.ts), a small
// prompt offers the guide chapter of that page and its Academy lesson (routes.ts). The guide opens in a side panel (a bottom
// sheet on a phone) over the page, which stays as it was: its scroll and every typed value are kept, and "Back to what I
// was doing" closes the panel and returns to the field they were in. Never on checkout, payment or signing steps. "Not now"
// quiets it on that page for a day. Settings > Program settings: on or off, the minutes and the errors.
const SNOOZE_MS = 24 * 3600_000;
const SETTINGS_KEY = 'cc-stuck-settings';
type Settings = { on?: boolean; idle_minutes?: number; errors?: number };
type Section = { slug: string; title: string; blurb: string | null; html: string };

const store = {
  get(k: string, s: Storage | undefined = undefined): string | null { try { return (s ?? localStorage).getItem(k); } catch { return null; } },
  set(k: string, v: string, s: Storage | undefined = undefined) { try { (s ?? localStorage).setItem(k, v); } catch { /* storage blocked: the prompt still works for this page */ } }
};
const tabOf = () => { const q = new URLSearchParams(window.location.search); return q.get('tab') ?? q.get('view') ?? null; };

export function StuckHelp({ portal }: { portal: HelpPortal }) {
  const pathname = usePathname();
  const [settings, setSettings] = useState<Settings | null>(() => {
    if (typeof window === 'undefined') return null;
    try { const c = store.get(SETTINGS_KEY, sessionStorage); return c ? (JSON.parse(c) as Settings) : null; } catch { return null; }
  });
  const [shownAt, setShown] = useState<{ trigger: StuckTrigger; name: string; path: string } | null>(null);
  const [panel, setPanel] = useState<{ loading: boolean; section: Section | null } | null>(null);
  const back = useRef<HTMLElement | null>(null);
  const closeBtn = useRef<HTMLButtonElement>(null);
  const help = pathname ? helpFor(pathname, typeof window === 'undefined' ? null : tabOf()) : null;
  const helpRef = useRef(help);
  useEffect(() => { helpRef.current = help; });
  const shown = shownAt && shownAt.path === pathname ? shownAt : null;

  const log = useCallback((action: string, trigger?: StuckTrigger) => {
    const h = helpRef.current;
    if (!h) return;
    void fetch('/api/help', { method: 'POST', keepalive: true, headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ portal: h.portal, route: h.pattern, tab: tabOf(), trigger: trigger ?? null, action }) }).catch(() => undefined);
  }, []);

  // the settings, once a session
  useEffect(() => {
    if (settings) return;
    let live = true;
    void fetch('/api/help', { cache: 'no-store' }).then((r) => (r.ok ? r.json() : null)).then((j: { settings?: Settings } | null) => {
      if (!live) return;
      const s = j?.settings ?? {};
      setSettings(s);
      store.set(SETTINGS_KEY, JSON.stringify(s), sessionStorage);
    }).catch(() => undefined);
    return () => { live = false; };
  }, [settings]);

  // the detector: one per page; fed by the page's events
  useEffect(() => {
    if (!settings || !help) return;
    const override = Number(store.get('cc-stuck-idle-ms') ?? '') || null;
    // automated browsers (the end-to-end tests) see it only when a test asks for it with its short timing
    if (navigator.webdriver && !override) return;
    const o = stuckOptions(settings, override);
    if (!o.on) return;
    const snoozed = Number(store.get(`cc-stuck-snooze:${help.pattern}`) ?? '0');
    if (snoozed > Date.now()) return;
    const d = new StuckDetector(o, Date.now());
    let lastStep = window.location.search + window.location.hash;
    const mine = (t: EventTarget | null) => t instanceof Element && !!t.closest('[data-stuck-ui]');
    const act = (e: Event) => { if (!mine(e.target)) d.activity(Date.now()); };
    const err = (e: Event) => { if (!mine(e.target)) d.error(Date.now()); };
    const ok = () => d.progress(Date.now());
    const seen = new WeakSet<Node>();
    const mo = new MutationObserver((ms) => {
      for (const m of ms) for (const n of m.addedNodes) {
        if (!(n instanceof Element) || mine(n)) continue;
        const alerts = [n, ...n.querySelectorAll('[role="alert"], .alert--error, .field__error')].filter((x) => x.matches('[role="alert"], .alert--error, .field__error'));
        for (const a of alerts) if (!seen.has(a) && (a.textContent ?? '').trim()) { seen.add(a); d.error(Date.now()); }
      }
    });
    mo.observe(document.body, { childList: true, subtree: true });
    document.addEventListener('pointerdown', act, true);
    document.addEventListener('keydown', act, true);
    document.addEventListener('input', act, true);
    document.addEventListener('invalid', err, true);
    window.addEventListener('cc:progress', ok);
    window.addEventListener('cc:error', err);
    const tick = window.setInterval(() => {
      const step = window.location.search + window.location.hash;
      if (step !== lastStep) { lastStep = step; d.step(step, Date.now()); }
      const t = d.check(Date.now());
      if (t) { setShown({ trigger: t, name: pageName(document.title), path: pathname ?? '' }); log('shown', t); }
    }, Math.min(1000, Math.max(250, o.idleMs / 4)));
    return () => {
      mo.disconnect();
      document.removeEventListener('pointerdown', act, true);
      document.removeEventListener('keydown', act, true);
      document.removeEventListener('input', act, true);
      document.removeEventListener('invalid', err, true);
      window.removeEventListener('cc:progress', ok);
      window.removeEventListener('cc:error', err);
      window.clearInterval(tick);
    };
    // a new page or new settings start over; the tab is read from the address when it fires
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pathname, settings, help?.pattern]);

  const openGuide = () => {
    if (!help) return;
    back.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setShown(null);
    setPanel({ loading: true, section: null });
    log('guide');
    void fetch(`/api/help?portal=${help.portal}&slug=${encodeURIComponent(help.guide)}`, { cache: 'no-store' })
      .then((r) => (r.ok ? r.json() : null)).then((j: { section?: Section | null } | null) => setPanel({ loading: false, section: j?.section ?? null }))
      .catch(() => setPanel({ loading: false, section: null }));
  };
  const close = useCallback(() => {
    setPanel(null);
    log('back');
    const el = back.current;
    if (el && document.contains(el)) el.focus({ preventScroll: true });
  }, [log]);
  useEffect(() => {
    if (!panel) return;
    closeBtn.current?.focus({ preventScroll: true });
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
    document.addEventListener('keydown', esc);
    return () => document.removeEventListener('keydown', esc);
  }, [panel, close]);

  if (!help) return null;
  return (<>
    {shown && !panel && (
      <section className="stk on-dark" role="region" aria-label="Help with this page" data-stuck-ui data-testid="stuck-prompt" data-portal={portal}>
        <p className="stk__q">Need a hand with {shown.name}?</p>
        <div className="stk__acts">
          <button type="button" className="btn btn--primary btn--sm" onClick={openGuide} data-testid="stuck-guide">Open the guide section</button>
          {help.lessonHref && <a className="btn btn--ghost btn--sm" href={help.lessonHref} target="_blank" rel="noopener" onClick={() => { log('lesson'); setShown(null); }} data-testid="stuck-lesson">Open the Academy lesson</a>}
          <button type="button" className="btn btn--quiet btn--sm" data-testid="stuck-snooze"
            onClick={() => { store.set(`cc-stuck-snooze:${help.pattern}`, String(Date.now() + SNOOZE_MS)); log('snooze'); setShown(null); }}>Not now</button>
        </div>
      </section>)}
    {panel && (
      <aside className="stk-panel" role="dialog" aria-modal="false" aria-labelledby="stk-title" data-stuck-ui data-testid="stuck-panel">
        <div className="stk-panel__bar">
          <button type="button" ref={closeBtn} className="btn btn--primary btn--sm" onClick={close} data-testid="stuck-back">Back to what I was doing</button>
          <a className="link small" href={help.guideHref} target="_blank" rel="noopener">Open the whole guide</a>
        </div>
        {/* the chapter scrolls on its own: reachable by keyboard to scroll it (a chapter can have no link in it) */}
        <div className="stk-panel__body" id={help.guide} tabIndex={0} role="region" aria-label="The guide chapter">
          {panel.loading ? <p className="small muted" role="status">Opening the guide...</p> : panel.section ? (<>
            <h2 className="d4" id="stk-title">{panel.section.title}</h2>
            {panel.section.blurb && <p className="small muted">{panel.section.blurb}</p>}
            <div className="gd-content stk-panel__html" dangerouslySetInnerHTML={{ __html: panel.section.html }} />
          </>) : (<>
            <h2 className="d4" id="stk-title">The guide</h2>
            <p className="small">This chapter is not published yet. <a className="link" href={help.guideHref} target="_blank" rel="noopener">Open the whole guide</a>.</p>
          </>)}
        </div>
      </aside>)}
  </>);
}
