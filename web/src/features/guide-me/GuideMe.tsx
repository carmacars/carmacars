'use client';
import './guide-me.css';
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { createPortal } from 'react-dom';
import { usePathname, useRouter } from 'next/navigation';
import { FLOWS, flowById } from './flows';
import { back as goBack, baseOf, canNext, currentStep, flowsFor, next as goNext, onPage, place, progress, routeMatches, selectorOf, skip as goSkip, startFor, startRun, sync, pageFirst, GUIDE_START_EVENT,
  type Box, type Flow, type Place, type Portal, type Probe, type Run } from './engine';

// Guide me (r51, migration 3950): the coach in every staff portal. Off by default; the header's Guide me button opens the
// menu (keep it on, and the workflows of the person's functions), and a page's "Guide me through this" link starts its
// workflow there. A run is kept on this device (it survives every page of the workflow and a reload) and on the server
// (resumed on another device; Admin sees the completions and the drop-off step). The coach mark never takes the page's
// clicks: a ring around the element (pointer-events none) and a small card beside it, clear of Report a bug.
const LOCAL = 'cc-guide-me-run';
const OFFERED = 'cc-guide-me-offered';
const GUIDE_HREF: Record<string, string> = { admin: '/admin/guide', va: '/staff/guide', field: '/staff/field/guide', owner: '/owner/guide', renter: '/account/guide', investor: '/investor/guide' };
// never over Report a bug, the field tabs, or a primary button other than the one it points at
const AVOID = '[data-testid="bug-report-open"], [data-bug-report-ui], .fp-tabs, .btn--primary';
const NONE: string[] = [];

const store = {
  get<T>(k: string, s?: Storage): T | null { try { const v = (s ?? localStorage).getItem(k); return v ? (JSON.parse(v) as T) : null; } catch { return null; } },
  set(k: string, v: unknown, s?: Storage) { try { if (v === null) (s ?? localStorage).removeItem(k); else (s ?? localStorage).setItem(k, JSON.stringify(v)); } catch { /* storage blocked: the run lasts for this page */ } }
};
// the public site (not signed in) keeps nothing on the server
let anonymous = false;
const post = (body: Record<string, unknown>) => anonymous ? Promise.resolve(null) : fetch('/api/guide-me', { method: 'POST', keepalive: true, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
  .then((r) => (r.ok ? (r.json() as Promise<{ ok?: boolean; id?: string }>) : null)).catch(() => null);

const visible = (el: Element) => el instanceof HTMLElement && el.getClientRects().length > 0 && !el.closest('[data-guide-me-ui]');
const find = (t: string): HTMLElement | null => {
  try { for (const el of document.querySelectorAll(selectorOf(t))) if (visible(el)) return el as HTMLElement; } catch { /* a malformed selector in a step file */ }
  return null;
};
const fieldOf = (el: HTMLElement | null) => (el && el.matches('input, select, textarea') ? el : el?.querySelector('input:not([type="hidden"]), select, textarea')) as HTMLInputElement | null;

/** The page as the engine reads it. */
function domProbe(clicks: Set<string>): Probe {
  return {
    path: window.location.pathname, search: window.location.search,
    exists: (t) => !!find(t),
    value: (t) => { const f = fieldOf(find(t)); return f ? f.value : null; },
    checked: (t) => { const el = find(t); if (!el) return false; if (el instanceof HTMLInputElement) return el.checked; return !!el.querySelector('input:checked'); },
    attr: (t, n) => { for (const el of document.querySelectorAll(selectorOf(t))) if (!el.closest('[data-guide-me-ui]')) return el.getAttribute(n); return null; },
    clicked: (t) => clicks.has(t)
  };
}

type View = { flow: Flow; run: Run } | null;
/** What the card shows of the page, read when the page changes (never during render) */
type Ui = { key: string; here: boolean; nextOk: boolean; ring: Box | null; card: Place | null };
const noop = () => () => {};
const localRun = (portal: Portal): View => {
  const local = typeof window === 'undefined' ? null : store.get<Run>(LOCAL);
  const f = local ? flowById(local.flow) : undefined;
  return local && f && local.portal === portal && Array.isArray(local.steps) ? { flow: f, run: local } : null;
};
const sameUi = (a: Ui | null, b: Ui) => !!a && a.key === b.key && a.here === b.here && a.nextOk === b.nextOk && JSON.stringify([a.ring, a.card]) === JSON.stringify([b.ring, b.card]);

export function GuideMe({ portal, admin = false, functions = NONE }: { portal: Portal; admin?: boolean; functions?: string[] }) {
  const pathname = usePathname();
  const router = useRouter();
  const fnKey = functions.join(' ');
  // eslint-disable-next-line react-hooks/exhaustive-deps -- the functions by value
  const mine = useMemo(() => flowsFor(FLOWS, { admin, functions, portal }), [admin, fnKey, portal]);
  const [on, setOn] = useState(false);
  const [menu, setMenu] = useState(false);
  // the run kept on this device (it survives every page and a reload); shown once the page is in the browser
  const [view, setView] = useState<View>(() => localRun(portal));
  const [done, setDone] = useState<string | null>(null);
  const [offered, setOffered] = useState<string[]>(() => (typeof window === 'undefined' ? [] : store.get<string[]>(OFFERED, sessionStorage) ?? []));
  const mounted = useSyncExternalStore(noop, () => true, () => false);
  const [ui, setUi] = useState<Ui | null>(null);
  const clicks = useRef(new Set<string>());
  const card = useRef<HTMLDivElement>(null);
  const btn = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<View>(null);
  useEffect(() => { viewRef.current = view; });

  const save = useCallback((v: View) => { store.set(LOCAL, v ? v.run : null); viewRef.current = v; setView(v); }, []);

  // the preference, and the run on the server when this device has none (resumed on another device)
  useEffect(() => {
    const local = localRun(portal);
    let live = true;
    void fetch('/api/guide-me', { cache: 'no-store' }).then((r) => { if (r.status === 401) anonymous = true; return r.ok ? r.json() : null; }).then((j: { anonymous?: boolean; on?: boolean; run?: { id: string; flow: string; portal: Portal; index: number; skipped: string[]; started_at: string } | null } | null) => {
      if (!live || !j) return;
      if (j.anonymous) anonymous = true;
      setOn(!!j.on);
      const r = j.run;
      if (!local && r && r.portal === portal) {
        const f = flowById(r.flow);
        const b = baseOf(window.location.pathname) ?? '/staff';
        if (f) { const run = startRun(f, portal, b, Date.parse(r.started_at) || Date.now()); setView({ flow: f, run: { ...run, id: r.id, index: Math.min(r.index, run.steps.length - 1), skipped: r.skipped ?? [] } }); }
      }
    }).catch(() => undefined);
    return () => { live = false; };
  }, [portal]);

  const start = useCallback((id: string) => {
    const f = flowById(id);
    if (!f || !mine.includes(f)) return;
    const b = baseOf(window.location.pathname) ?? (portal === 'admin' ? '/admin' : '/staff');
    clicks.current.clear();
    const r0 = startRun(f, portal, b, Date.now());
    const o = sync(f, r0, domProbe(clicks.current));
    const run = o.run;
    setMenu(false); setDone(null);
    save({ flow: f, run });
    void post({ op: 'start', flow: f.id, portal, total: run.steps.length, step: run.steps[run.index] ?? null }).then((x) => {
      const v = viewRef.current;
      if (x?.id && v && v.run.startedAt === run.startedAt) save({ flow: v.flow, run: { ...v.run, id: x.id } });
    });
    const s = currentStep(f, run);
    const here = startFor(f, portal, b);
    if (s && !onPage(s, domProbe(clicks.current), b) && !routeMatches(here.split('?')[0]!, window.location.pathname, '', b)) router.push(here);
  }, [mine, portal, router, save]);

  const finish = useCallback((status: 'completed' | 'exited') => {
    const v = viewRef.current;
    if (!v) return;
    void post({ op: 'end', run: v.run.id, status, index: v.run.index, step: v.run.steps[v.run.index] ?? null, skipped: v.run.skipped });
    if (status === 'completed') setDone(v.flow.title);
    save(null);
  }, [save]);

  // a page's "Guide me through this" link
  useEffect(() => {
    const go = (e: Event) => { const id = (e as CustomEvent<{ flow?: string }>).detail?.flow; if (id) start(id); };
    window.addEventListener(GUIDE_START_EVENT, go);
    return () => window.removeEventListener(GUIDE_START_EVENT, go);
  }, [start]);

  // kept on: on the first page of a workflow, a quiet offer (once a session for each workflow)
  const offer = useMemo(() => {
    if (!on || view || !mounted || !pathname) return null;
    const b = baseOf(pathname) ?? '/staff';
    return mine.find((x) => !offered.includes(x.id) && routeMatches(startFor(x, portal, b), pathname, '', b)) ?? null;
  }, [on, view, mounted, pathname, mine, portal, offered]);

  // every change of the page: the engine looks again
  const look = useCallback(() => {
    const v = viewRef.current;
    if (!v) { setUi(null); return; }
    const pr = domProbe(clicks.current);
    const o = sync(v.flow, v.run, pr);
    if (o.kind === 'completed') { finish('completed'); return; }
    if (o.run.index !== v.run.index) {
      clicks.current.clear();
      save({ flow: v.flow, run: o.run });
      void post({ op: 'step', run: o.run.id, index: o.run.index, step: o.run.steps[o.run.index] ?? null, skipped: o.run.skipped });
    } else if (o.run !== v.run) save({ flow: v.flow, run: o.run });
    // what the card shows, and where the ring and the card go
    const s = currentStep(v.flow, o.run);
    if (!s) return;
    const here = onPage(s, pr, o.run.base);
    const el = here && s.target ? find(s.target) : null;
    const vw = document.documentElement.clientWidth; const vh = window.innerHeight;
    const rb = el?.getBoundingClientRect();
    const ring = rb ? { x: rb.left - 4, y: rb.top - 4, w: rb.width + 8, h: rb.height + 8 } : null;
    const avoid = [...document.querySelectorAll(AVOID)].filter((e) => visible(e) && !(el && (e === el || e.contains(el) || el.contains(e))) && e.getBoundingClientRect().bottom > 0 && e.getBoundingClientRect().top < vh).slice(0, 24).map((e) => { const r = e.getBoundingClientRect(); return { x: r.left - 6, y: r.top - 6, w: r.width + 12, h: r.height + 12 }; });
    const ch = card.current?.getBoundingClientRect().height || 170;
    const next: Ui = { key: `${v.flow.id}:${o.run.index}`, here, nextOk: canNext(s, pr, o.run.base), ring, card: card.current ? place(ring, { w: Math.min(352, vw - 32), h: ch }, { w: vw, h: vh }, avoid) : null };
    setUi((old) => (sameUi(old, next) ? old : next));
  }, [finish, save]);

  useEffect(() => {
    if (!view) return;
    let raf = 0;
    const soon = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(look); };
    const clicked = (e: Event) => {
      const v = viewRef.current; const s = v && currentStep(v.flow, v.run);
      if (s?.target && e.target instanceof Element && e.target.closest(selectorOf(s.target)) && !e.target.closest('[data-guide-me-ui]')) clicks.current.add(s.target);
      soon();
    };
    const mo = new MutationObserver(soon);
    mo.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-ok', 'data-missing', 'data-pending', 'data-sent', 'data-kind', 'open', 'class', 'value'] });
    document.addEventListener('input', soon, true);
    document.addEventListener('change', soon, true);
    document.addEventListener('click', clicked, true);
    window.addEventListener('resize', soon);
    window.addEventListener('scroll', soon, true);
    const t = window.setInterval(soon, 800);
    soon();
    return () => { mo.disconnect(); cancelAnimationFrame(raf); window.clearInterval(t); document.removeEventListener('input', soon, true); document.removeEventListener('change', soon, true);
      document.removeEventListener('click', clicked, true); window.removeEventListener('resize', soon); window.removeEventListener('scroll', soon, true); };
  }, [view, look, pathname]);

  const step = view ? currentStep(view.flow, view.run) : null;
  const stepKey = view ? `${view.flow.id}:${view.run.index}` : '';
  const shown = ui && ui.key === stepKey ? ui : null;
  const here = shown ? shown.here : true;

  // a new step: its element into view
  useEffect(() => {
    if (!stepKey) return;
    const s = viewRef.current && currentStep(viewRef.current.flow, viewRef.current.run);
    const el = s?.target ? find(s.target) : null;
    if (!el) return;
    const r = el.getBoundingClientRect();
    if (r.top < 64 || r.bottom > window.innerHeight - 160) el.scrollIntoView({ block: 'center', behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }, [stepKey]);

  // the menu: Escape and a click outside close it
  useEffect(() => {
    if (!menu) return;
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') { setMenu(false); btn.current?.focus(); } };
    const out = (e: PointerEvent) => { if (!menuRef.current?.contains(e.target as Node) && !btn.current?.contains(e.target as Node)) setMenu(false); };
    document.addEventListener('keydown', k); document.addEventListener('pointerdown', out, true);
    return () => { document.removeEventListener('keydown', k); document.removeEventListener('pointerdown', out, true); };
  }, [menu]);

  // the done note goes by itself
  useEffect(() => { if (!done) return; const t = window.setTimeout(() => setDone(null), 6000); return () => window.clearTimeout(t); }, [done]);

  const keepOn = (v: boolean) => { setOn(v); void post({ op: 'pref', on: v }); };
  const act = (what: 'next' | 'back' | 'skip') => {
    const v = viewRef.current; if (!v) return;
    const p = domProbe(clicks.current);
    if (what === 'back') { clicks.current.clear(); save({ flow: v.flow, run: goBack(v.flow, v.run, p) }); return; }
    const o = what === 'next' ? goNext(v.flow, v.run, p) : goSkip(v.flow, v.run, p);
    clicks.current.clear();
    if (o.kind === 'completed') { save({ flow: v.flow, run: o.run }); finish('completed'); return; }
    save({ flow: v.flow, run: o.run });
    void post({ op: 'step', run: o.run.id, index: o.run.index, step: o.run.steps[o.run.index] ?? null, skipped: o.run.skipped });
  };
  const dismissOffer = (f: Flow) => { const n = [...offered, f.id]; store.set(OFFERED, n, sessionStorage); setOffered(n); };

  if (!mine.length) return null;
  const groups = menu ? pageFirst(mine, portal, pathname ?? '', typeof window === 'undefined' ? '' : window.location.search) : { here: [], rest: [] };
  const item = (f: Flow) => <li key={f.id}><button type="button" onClick={() => start(f.id)} data-testid={`guide-me-start-${f.id}`}><b>{f.title}</b><span>{f.summary}</span></button></li>;
  const pg = view ? progress(view.run) : null;
  const nextOk = !!shown?.nextOk;
  const pos = shown && shown.card ? { ring: shown.ring, card: shown.card } : null;
  const href = step?.href && view ? step.href.replace('{base}', view.run.base) : null;
  const guide = view?.flow.guide && GUIDE_HREF[view.flow.guide.portal] && view.flow.guide.portal === portal ? `${GUIDE_HREF[portal]}#${view.flow.guide.slug}` : null;
  return (<>
    <span className="gm-anchor">
      <button ref={btn} type="button" className={`btn btn--quiet btn--sm hd-act gm-btn${mounted && (on || view) ? ' is-on' : ''}`} title="Guide me" aria-haspopup="true" aria-expanded={menu}
        onClick={() => setMenu(!menu)} data-testid="guide-me-open" data-guide-me-ui>
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5" /><path d="M15.5 8.5l-2 5-5 2 2-5z" /></svg>
        <span className="hd-lbl">Guide me</span>
      </button>
      {menu && <div ref={menuRef} className="gm-menu mo-pop-in" role="dialog" aria-label="Guide me" data-testid="guide-me-menu" data-guide-me-ui>
        <label className="gm-switch" htmlFor="gm-keep">
          <input id="gm-keep" type="checkbox" role="switch" checked={on} onChange={(e) => keepOn(e.target.checked)} data-testid="guide-me-keep" />
          <span><b>Keep Guide me on</b><span className="small muted">On the first page of a workflow, it offers to walk you through it.</span></span>
        </label>
        {groups.here.length > 0 && <><p className="gm-menu__h">On this page</p>
          <ul className="gm-flows" data-testid="guide-me-here">{groups.here.map(item)}</ul></>}
        {groups.rest.length > 0 && <><p className="gm-menu__h">{groups.here.length ? 'Everything else' : 'Walk me through'}</p>
          <ul className="gm-flows" data-testid="guide-me-all">{groups.rest.map(item)}</ul></>}
        {mounted && view && <p className="gm-menu__foot"><button type="button" className="btn btn--quiet btn--sm" onClick={() => { setMenu(false); finish('exited'); }} data-testid="guide-me-stop">Stop the guide</button></p>}
      </div>}
    </span>
    {mounted && createPortal(<>
      {view && step && pos?.ring && <div className="gm-ring" aria-hidden="true" style={{ transform: `translate(${pos.ring.x}px, ${pos.ring.y}px)`, width: pos.ring.w, height: pos.ring.h }} data-guide-me-ui />}
      {view && step && pg && (
        <div ref={card} key={stepKey} className={`gm-card gm-card--${pos?.card.side ?? 'float'}`} role="dialog" aria-modal="false" aria-labelledby="gm-text" data-guide-me-ui data-testid="guide-me-card"
          data-step={step.id} style={pos ? { transform: `translate(${pos.card.x}px, ${pos.card.y}px)` } : { visibility: 'hidden' }}>
          {pos?.card.arrowX != null && <span className="gm-card__arrow" style={{ left: pos.card.arrowX }} aria-hidden="true" />}
          <p className="gm-card__top"><span className="gm-card__flow">{view.flow.title}</span><span className="gm-card__n" data-testid="guide-me-progress">Step {pg.at} of {pg.of}</span></p>
          <div className="gm-card__bar" aria-hidden="true"><span style={{ width: `${Math.round((pg.at / pg.of) * 100)}%` }} /></div>
          <p className="gm-card__text" id="gm-text" aria-live="polite" data-testid="guide-me-text">{step.text}</p>
          {!here && href && <p className="small"><a className="link" href={href} onClick={(e) => { e.preventDefault(); router.push(href); }} data-testid="guide-me-go">Go to the page</a></p>}
          {nextOk && step.done && !step.read && <p className="gm-card__ok small" role="status"><span aria-hidden="true">✓</span> Done</p>}
          <div className="gm-card__acts">
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => act('back')} disabled={view.run.index === 0} title={view.run.index === 0 ? 'This is the first step' : undefined} data-testid="guide-me-back">Back</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => act('skip')} data-testid="guide-me-skip">Skip</button>
            <button type="button" className="btn btn--primary btn--sm" onClick={() => act('next')} disabled={!nextOk} data-testid="guide-me-next"
              title={nextOk ? undefined : 'Do this step on the page: it moves on by itself'}>{view.run.index + 1 >= view.run.steps.length ? 'Finish' : 'Next'}</button>
            <button type="button" className="gm-card__x k-hit" onClick={() => finish('exited')} aria-label="Exit the guide" data-testid="guide-me-exit">
              <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg></button>
          </div>
          {guide && <p className="gm-card__more small"><a className="link" href={guide} target="_blank" rel="noopener">Read the guide chapter</a></p>}
        </div>)}
      {!view && offer && (
        <div className="gm-card gm-card--offer" role="dialog" aria-modal="false" aria-label="Guide me" data-guide-me-ui data-testid="guide-me-offer">
          <p className="gm-card__text"><b>Guide me through {offer.title.charAt(0).toLowerCase() + offer.title.slice(1)}?</b></p>
          <div className="gm-card__acts"><button type="button" className="btn btn--primary btn--sm" onClick={() => start(offer.id)} data-testid="guide-me-offer-start">Start</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => dismissOffer(offer)} data-testid="guide-me-offer-no">Not now</button></div>
        </div>)}
      {done && <div className="gm-card gm-card--offer gm-card--done" role="status" data-guide-me-ui data-testid="guide-me-done"><p className="gm-card__text"><span aria-hidden="true">✓</span> {done}: all done.</p></div>}
    </>, document.body)}
  </>);
}
