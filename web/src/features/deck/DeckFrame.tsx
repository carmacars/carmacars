'use client';
import { useCallback, useEffect, useRef, useState } from 'react';

// The deck's frame: the slide counter, previous and next, a jump list, keyboard (arrows, Page Up and Down, Home, End)
// and swipe (left and right) navigation, and Download PDF (the browser's print to PDF, one slide per landscape page).
export function DeckFrame({ titles, children }: { titles: string[]; children: React.ReactNode }) {
  const root = useRef<HTMLDivElement>(null);
  const [cur, setCur] = useState(0);
  const slides = useCallback(() => Array.from(root.current?.querySelectorAll<HTMLElement>('.dk-slide') ?? []), []);
  const go = useCallback((i: number) => {
    const all = slides();
    const k = Math.max(0, Math.min(all.length - 1, i));
    all[k]?.scrollIntoView({ block: 'start' });
    all[k]?.focus({ preventScroll: true });
    setCur(k);
  }, [slides]);

  useEffect(() => {
    document.documentElement.classList.add('dk-on');
    return () => document.documentElement.classList.remove('dk-on');
  }, []);

  // which slide is in view
  useEffect(() => {
    const all = slides();
    const io = new IntersectionObserver((es) => {
      for (const e of es) if (e.isIntersecting) { const k = all.indexOf(e.target as HTMLElement); if (k >= 0) setCur(k); }
    }, { rootMargin: '-35% 0px -60% 0px' });
    all.forEach((s) => io.observe(s));
    return () => io.disconnect();
  }, [slides]);

  // keyboard: not while typing in the calculator
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.closest('input, select, textarea, [contenteditable], details summary') || e.altKey || e.ctrlKey || e.metaKey)) return;
      if (e.key === 'ArrowRight' || e.key === 'PageDown' || (e.key === 'ArrowDown' && e.shiftKey)) { e.preventDefault(); go(cur + 1); }
      else if (e.key === 'ArrowLeft' || e.key === 'PageUp' || (e.key === 'ArrowUp' && e.shiftKey)) { e.preventDefault(); go(cur - 1); }
      else if (e.key === 'Home') { e.preventDefault(); go(0); }
      else if (e.key === 'End') { e.preventDefault(); go(slides().length - 1); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [cur, go, slides]);

  // swipe: a mostly horizontal stroke of 60 px or more
  useEffect(() => {
    const el = root.current;
    if (!el) return;
    let sx = 0, sy = 0, on = false;
    const start = (e: TouchEvent) => { if (e.touches.length !== 1 || (e.target as HTMLElement).closest('.dk-scroll, .dk-calc__table, input, select')) { on = false; return; } on = true; sx = e.touches[0]!.clientX; sy = e.touches[0]!.clientY; };
    const end = (e: TouchEvent) => {
      if (!on) return; on = false;
      const t0 = e.changedTouches[0]; if (!t0) return; const dx = t0.clientX - sx, dy = t0.clientY - sy;
      if (Math.abs(dx) >= 60 && Math.abs(dx) > Math.abs(dy) * 1.5) go(cur + (dx < 0 ? 1 : -1));
    };
    el.addEventListener('touchstart', start, { passive: true });
    el.addEventListener('touchend', end, { passive: true });
    return () => { el.removeEventListener('touchstart', start); el.removeEventListener('touchend', end); };
  }, [cur, go]);

  return (
    <div className="dk-deck" ref={root} data-testid="deck">
      <div className="dk-tools" role="toolbar" aria-label="Slides">
        <div className="dk-tools__nav">
          <button type="button" className="btn btn--ghost btn--sm" onClick={() => go(cur - 1)} disabled={cur === 0} aria-label="Previous slide" data-testid="deck-prev">Previous</button>
          <span className="dk-tools__count" aria-live="polite" data-testid="deck-count">{cur + 1} / {titles.length}</span>
          <button type="button" className="btn btn--ghost btn--sm" onClick={() => go(cur + 1)} disabled={cur >= titles.length - 1} aria-label="Next slide" data-testid="deck-next">Next</button>
        </div>
        <label className="vh" htmlFor="dk-jump">Go to slide</label>
        <select id="dk-jump" className="select dk-tools__jump" value={cur} onChange={(e) => go(Number(e.target.value))}>
          {titles.map((t, i) => <option key={i} value={i}>{i + 1}. {t}</option>)}
        </select>
        <span className="dk-hint">Arrow keys or swipe to move</span>
        <button type="button" className="btn btn--primary btn--sm" onClick={() => window.print()} data-testid="deck-pdf">Download PDF</button>
      </div>
      {children}
    </div>
  );
}
