'use client';
import { useRouter } from 'next/navigation';
import { useEffect, useRef, useState, useSyncExternalStore, useTransition } from 'react';
import { pullDistance, PULL } from './model';
import './pull-refresh.css';

// r50: drag down from the top to refresh, where the browser gives none: the CarmaCars app (<html data-shell="app">, whose
// body turns the bounce off) and the site added to a home screen (display-mode standalone). A phone browser keeps its own
// pull to refresh, so nothing is added there. The page's data is fetched again in place (router.refresh: forms, open tabs
// and scroll stay), never a full reload. Touch only; one finger; vertical; from the very top; not while a dialog, a menu
// or a scrolled inner list has the touch.
const noop = () => () => undefined;
function wanted(): boolean {
  const standalone = window.matchMedia?.('(display-mode: standalone)').matches || (navigator as { standalone?: boolean }).standalone === true;
  const touch = 'ontouchstart' in window || navigator.maxTouchPoints > 0;
  return touch && (document.documentElement.dataset.shell === 'app' || !!standalone);
}

export function PullToRefresh() {
  const router = useRouter();
  const on = useSyncExternalStore(noop, wanted, () => false);
  const [pull, setPull] = useState(0);
  const [busy, setBusy] = useState(false);
  const [pending, start] = useTransition();
  const from = useRef<{ x: number; y: number; vertical: boolean | null } | null>(null);
  const pullRef = useRef(0);

  useEffect(() => {
    if (!on) return;
    const d = document.documentElement;
    d.dataset.ptr = 'on';
    return () => { delete d.dataset.ptr; };
  }, [on]);

  useEffect(() => { if (!pending && busy) { const t = setTimeout(() => setBusy(false), 350); return () => clearTimeout(t); } }, [pending, busy]);

  useEffect(() => {
    if (!on) return;
    const blocked = (t: EventTarget | null) => {
      const el = t instanceof Element ? t : null;
      if (!el) return true;
      if (el.closest('dialog[open], [role="dialog"], [aria-modal="true"], .menu-panel.is-open, input, textarea, select, [contenteditable="true"], [data-no-ptr]')) return true;
      for (let n: Element | null = el; n && n !== document.body; n = n.parentElement) if (n.scrollTop > 0) return true;
      return false;
    };
    const down = (e: TouchEvent) => {
      if (busy || e.touches.length !== 1 || window.scrollY > 0 || document.documentElement.style.overflow === 'hidden' || blocked(e.target)) { from.current = null; return; }
      from.current = { x: e.touches[0]!.clientX, y: e.touches[0]!.clientY, vertical: null };
    };
    const move = (e: TouchEvent) => {
      const f = from.current;
      if (!f || e.touches.length !== 1) return;
      const dx = e.touches[0]!.clientX - f.x, dy = e.touches[0]!.clientY - f.y;
      if (f.vertical === null && Math.abs(dx) + Math.abs(dy) > 8) f.vertical = Math.abs(dy) > Math.abs(dx) && dy > 0;
      if (!f.vertical || window.scrollY > 0) { if (pullRef.current) { pullRef.current = 0; setPull(0); } return; }
      if (e.cancelable) e.preventDefault();
      pullRef.current = pullDistance(dy);
      setPull(pullRef.current);
    };
    const up = () => {
      const p = pullRef.current;
      from.current = null; pullRef.current = 0; setPull(0);
      if (p >= PULL.trigger) {
        setBusy(true);
        try { navigator.vibrate?.(8); } catch { /* not every phone */ }
        start(() => router.refresh());
      }
    };
    window.addEventListener('touchstart', down, { passive: true });
    window.addEventListener('touchmove', move, { passive: false });
    window.addEventListener('touchend', up, { passive: true });
    window.addEventListener('touchcancel', up, { passive: true });
    return () => {
      window.removeEventListener('touchstart', down); window.removeEventListener('touchmove', move);
      window.removeEventListener('touchend', up); window.removeEventListener('touchcancel', up);
    };
  }, [on, busy, router]);

  if (!on) return null;
  const shown = busy ? PULL.rest : pull;
  const ready = pull >= PULL.trigger;
  return (
    <div className={`ptr${shown > 0 ? ' is-shown' : ''}${busy ? ' is-busy' : ''}${ready ? ' is-ready' : ''}`} data-testid="ptr" aria-hidden={!busy}
      style={{ transform: `translate(-50%, ${Math.round(shown - PULL.size)}px)` }}>
      <span className="ptr__dot" style={{ transform: busy ? undefined : `rotate(${Math.round(Math.min(1, pull / PULL.trigger) * 270)}deg)` }} aria-hidden="true" />
      <span className="vh" role="status">{busy ? 'Refreshing' : ''}</span>
    </div>
  );
}
