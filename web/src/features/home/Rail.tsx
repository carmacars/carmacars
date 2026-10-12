'use client';
import { useEffect, useRef, useState, type ReactNode } from 'react';

// Horizontal rail with scroll snap, arrow buttons and a progress bar (prototype [data-rail]).
// Featured cars: a random pick of `count` on each visit (site_settings.featured_mode = random),
// otherwise the listings marked featured, in order.
export function Rail({ head, items, end, count, random }: { head: ReactNode; items: { key: string; node: ReactNode; featured: boolean }[]; end: ReactNode; count: number; random: boolean }) {
  const rail = useRef<HTMLUListElement>(null);
  const bar = useRef<HTMLElement>(null);
  const [order, setOrder] = useState<number[]>(() => {
    const idx = items.map((_, i) => i);
    const pref = random ? idx : idx.filter((i) => items[i]!.featured).concat(idx.filter((i) => !items[i]!.featured));
    return pref.slice(0, count);
  });
  const [edge, setEdge] = useState({ start: true, end: false });

  useEffect(() => {
    if (!random) return;
    const idx = items.map((_, i) => i);
    for (let i = idx.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [idx[i], idx[j]] = [idx[j]!, idx[i]!]; }
    // eslint-disable-next-line react-hooks/set-state-in-effect -- the random pick must follow hydration
    setOrder(idx.slice(0, count));
  }, [items, count, random]);

  useEffect(() => {
    const r = rail.current; if (!r) return;
    const native = CSS.supports?.('animation-timeline: scroll()');
    let ticking = false;
    const sync = () => {
      ticking = false; const max = r.scrollWidth - r.clientWidth; const k = max > 0 ? r.scrollLeft / max : 0;
      setEdge({ start: r.scrollLeft < 4, end: r.scrollLeft > max - 4 });
      if (bar.current && !native) bar.current.style.transform = `scaleX(${Math.max(0.08, k)})`;
    };
    const on = () => { if (!ticking) { ticking = true; requestAnimationFrame(sync); } };
    r.addEventListener('scroll', on, { passive: true }); sync();
    return () => r.removeEventListener('scroll', on);
  }, [order]);

  const step = () => { const c = rail.current?.firstElementChild; return c ? c.getBoundingClientRect().width + parseFloat(getComputedStyle(rail.current!).columnGap || '0') : 300; };
  const go = (dir: number) => rail.current?.scrollBy({ left: dir * step(), behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });

  return (
    <>
      <div className="wrap section-head">
      {head}
      <div className="row rail-ctrl">
        <button type="button" className="icon-btn" aria-label="Previous cars" disabled={edge.start} onClick={() => go(-1)}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></button>
        <button type="button" className="icon-btn" aria-label="More cars" disabled={edge.end} onClick={() => go(1)}><svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" /></svg></button>
      </div>
      </div>
      <ul className="rail" tabIndex={0} aria-label="Featured cars, scroll sideways" ref={rail}>
        {order.map((i) => <li key={items[i]!.key}>{items[i]!.node}</li>)}
        <li className="rail__end">{end}</li>
      </ul>
      <div className="wrap"><div className="rail-progress" aria-hidden="true"><i ref={bar}></i></div></div>
    </>
  );
}
